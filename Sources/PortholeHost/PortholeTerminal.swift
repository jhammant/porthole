import Foundation
import Network
import StreamProtocol

/// Porthole (docs/porthole-plan.md, Terminal): an iTerm2 session's screen as text for the device (kinds
/// 205–207). The host reads the session's text through AppleScript four times a second while a device
/// watches it, and sends only the lines that changed; keys come back as the bytes a terminal would send
/// and are written into the session.
///
/// AppleScript runs in a helper process (PortholeOSAHelper), compiled once (a read takes ~50 ms; osascript
/// took ~300 ms). Not in the host: AppleScript must run on a main thread (off it, the window server traps),
/// and on the host's, a slow iTerm2 froze the stream while it waited for an answer (both found 16–17 Oct).
/// Everything else is on a queue of its own, so the 2 s session lookups never stall a terminal. Colours and the cursor need iTerm's
/// Python API, which asks Jon's permission the first time a script it did not launch connects: not until
/// he turns that on. Until then the device colours Claude Code's marks itself.
final class PortholeTerminalFeed: @unchecked Sendable {
    private let server: StreamServer
    private let queue = DispatchQueue(label: "porthole.terminal", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let osa = PortholeOSA()
    /// The screen with its colours, through iTerm's Python API (docs/agent-view-plan.md, phase 2); text
    /// through AppleScript when that isn't there.
    private let iterm = PortholeITermScreen()

    private struct Watch {
        let connection: NWConnection
        let terminalID: String
        let windowID: UInt32?
        var lines: [String] = []
        var runs: [[TerminalRun]] = []
        var columns = 0
        var rows = 0
        /// The session's own size before Porthole fitted it to the device, put back when the watch ends.
        var home: (columns: Int, rows: Int)?
        /// Porthole (22 Oct, the two-finger scroll): the line of the session's history the pane shows first
        /// (iTerm's numbering), so new output never moves what is being read; nil follows the live screen.
        var first: Int?
        /// The find in this session (TerminalView's `find`): its matches, oldest first, and the one shown.
        var find: Find?
        /// What the last screen said of the scroll and the find, so a change of either alone still goes out.
        var sentMeta: Meta?
    }

    struct Find {
        var query: String
        var matches: [(line: Int, column: Int)]
        var index: Int
    }

    struct Meta: Equatable {
        var scrolledUp: Int
        var history: Int
        var find: TerminalFind?
    }
    private var watches: [ObjectIdentifier: Watch] = [:]
    private var inputTimes: [ObjectIdentifier: [CFAbsoluteTime]] = [:]
    private var pending: [String: (windowID: UInt32?, text: String)] = [:]
    /// Sessions fitted to a device, with their own size, behind a lock: the host's shutdown reads it on
    /// the main thread, which must never wait on this queue (it may be waiting on main for AppleScript).
    private let fittedLock = NSLock()
    private var fitted: [String: (windowID: UInt32?, columns: Int, rows: Int)] = [:]

    init(server: StreamServer) { self.server = server }

    func watch(_ request: TerminalRequest, from connection: NWConnection) {
        queue.async {
            let id = ObjectIdentifier(connection)
            let previous = self.watches[id]
            if request.stop == true { self.end(id); self.stopIfIdle(); return }
            // Porthole: the colour set the device asked for; a change sends every watched screen whole again.
            if self.iterm.colours != request.colours {
                self.iterm.colours = request.colours
                for k in self.watches.keys { self.watches[k]?.runs = [] }
            }
            // A device that has gone fits nothing.
            if case .cancelled = connection.state { return }
            if case .failed = connection.state { return }
            // Another session (or a new fit of the same one): the old session goes back to its size first,
            // unless it is the same session, whose home is kept.
            var home = previous?.terminalID == request.terminalID ? previous?.home : nil
            if previous != nil, previous?.terminalID != request.terminalID { self.end(id) }
            // One own size per session, whoever fitted it first (22 Oct review): a quick reconnect, or a
            // second device, read the first device's fit as the session's own and left it at that size.
            if home == nil {
                self.fittedLock.lock()
                home = self.fitted[request.terminalID].map { ($0.columns, $0.rows) }
                self.fittedLock.unlock()
            }
            if let c = request.fitColumns, let r = request.fitRows {
                let cols = min(max(c, 40), 300), rows = min(max(r, 10), 120)
                let before = self.osa.call("resizeto", [String(request.windowID ?? 0), request.terminalID, String(cols), String(rows)])
                let parts = (before ?? "").split(separator: ",").compactMap { Int($0) }
                if home == nil, parts.count == 2 { home = (parts[0], parts[1]) }
                print("Porthole: terminal fitted to \(cols)×\(rows) for \(connection.endpoint)" + (home.map { " (its own size \($0.columns)×\($0.rows))" } ?? " (its own size unknown)"))
            }
            var w = Watch(connection: connection, terminalID: request.terminalID, windowID: request.windowID)
            w.home = home
            // The same session again (the pane refitted, the colours changed): its find stays. A refit rewraps
            // the history, so its matches are found again and the view goes back to live.
            if previous?.terminalID == request.terminalID, let f = previous?.find {
                let matches = self.iterm.find(request.terminalID, f.query)?.matches ?? []
                w.find = Find(query: f.query, matches: matches, index: matches.count - 1)
            }
            if let home {
                self.fittedLock.lock()
                if self.fitted[request.terminalID] == nil { self.fitted[request.terminalID] = (request.windowID, home.columns, home.rows) }
                self.fittedLock.unlock()
            }
            self.watches[id] = w
            self.refresh(id)
            if self.timer == nil { self.start() }
        }
    }

    /// Porthole: where a pane looks in its session's history, and what it finds there (kind 213).
    func view(_ view: TerminalView, from connection: NWConnection) {
        queue.async {
            let id = ObjectIdentifier(connection)
            guard var w = self.watches[id], w.terminalID == view.terminalID else { return }
            var scrolledUp: Int?
            if view.endFind == true {
                w.find = nil
            } else if let raw = view.find {
                let query = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(PortholeWire.maxSearchQuery))
                guard !query.isEmpty else { return }
                let step = max(-1, min(1, view.step ?? 0))
                if step == 0 || w.find?.query != query {
                    let found = self.iterm.find(w.terminalID, query)
                    let matches = found?.matches ?? []
                    w.find = Find(query: query, matches: matches, index: matches.count - 1)
                    print("Porthole: find in a terminal, \(matches.count) matches" + (found == nil ? " (no iTerm helper)" : ""))
                } else if var f = w.find, !f.matches.isEmpty {
                    let n = f.matches.count
                    f.index = ((f.index + step) % n + n) % n
                    w.find = f
                }
                // The match shown a third of the way down the pane, or the live screen when it is there.
                if let f = w.find, f.matches.indices.contains(f.index) {
                    w.first = f.matches[f.index].line - max(0, w.rows / 3)
                }
            } else if let up = view.scrolledUp {
                w.first = nil
                scrolledUp = max(0, min(up, 1_000_000))
            }
            w.runs = []
            self.watches[id] = w
            self.refresh(id, scrolledUp: scrolledUp)
        }
    }

    func input(_ input: TerminalInput, from connection: NWConnection, arrived: CFAbsoluteTime) {
        queue.async {
            let id = ObjectIdentifier(connection)
            // Only into the terminal this device watches: an id alone never opens a session to typing.
            guard var w = self.watches[id], w.terminalID == input.terminalID, input.text.utf8.count <= PortholeWire.maxTerminalInput else { return }
            // Typing shows the live screen again, as a terminal does.
            if w.first != nil { w.first = nil; w.runs = []; self.watches[id] = w }
            var recent = (self.inputTimes[id] ?? []).filter { arrived - $0 < 1 }
            guard recent.count < PortholeWire.terminalInputsPerSecond else { self.inputTimes[id] = recent; return }
            recent.append(arrived)
            self.inputTimes[id] = recent
            // Keys that arrive while a write runs go out together in the next one.
            let before = self.pending[input.terminalID]?.text ?? ""
            self.pending[input.terminalID] = (w.windowID, before + input.text)
            if before.isEmpty { self.queue.async { self.flush(input.terminalID) } }
        }
    }

    func clientLeft(_ connection: NWConnection) {
        queue.async {
            let id = ObjectIdentifier(connection)
            self.end(id)
            self.inputTimes[id] = nil
            self.stopIfIdle()
        }
    }

    /// A watch ends: its session goes back to its own size, unless another device still watches it.
    private func end(_ id: ObjectIdentifier) {
        guard let w = watches.removeValue(forKey: id) else { return }
        guard let home = w.home, !watches.values.contains(where: { $0.terminalID == w.terminalID }) else {
            print("Porthole: terminal watch ended for \(w.connection.endpoint)" + (w.home == nil ? ", nothing to put back" : ", still watched elsewhere"))
            return
        }
        _ = osa.call("resizeto", [String(w.windowID ?? 0), w.terminalID, String(home.columns), String(home.rows)])
        print("Porthole: terminal back to its own size \(home.columns)×\(home.rows)")
        fittedLock.lock(); fitted[w.terminalID] = nil; fittedLock.unlock()
    }

    /// The host is stopping: every fitted session goes back to its own size (on the main thread, which is
    /// where AppleScript runs).
    func restoreAll() {
        fittedLock.lock(); let all = fitted; fitted = [:]; fittedLock.unlock()
        for (terminalID, f) in all {
            _ = osa.call("resizeto", [String(f.windowID ?? 0), terminalID, String(f.columns), String(f.rows)])
        }
    }

    // MARK: Reading

    private func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + PortholeWire.terminalRefreshSeconds, repeating: PortholeWire.terminalRefreshSeconds, leeway: .milliseconds(30))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            for id in self.watches.keys { self.refresh(id) }
        }
        t.resume()
        timer = t
    }

    private func stopIfIdle() {
        guard watches.isEmpty else { return }
        timer?.cancel()
        timer = nil
    }

    private func refresh(_ id: ObjectIdentifier, scrolledUp: Int? = nil) {
        guard var w = watches[id] else { return }
        if let styled = iterm.screen(w.terminalID, first: w.first, scrolledUp: scrolledUp) {
            let full = w.runs.isEmpty || styled.columns != w.columns || styled.rows != w.rows
            var changed: [TerminalLine] = []
            for (row, runs) in styled.lines.enumerated() where full || row >= w.runs.count || w.runs[row] != runs {
                changed.append(TerminalLine(row: row, runs: runs))
            }
            w.runs = styled.lines; w.columns = styled.columns; w.rows = styled.rows
            // Scrolled up, the pane keeps its lines as output arrives; at the live screen it follows it.
            w.first = styled.first < styled.base ? styled.first : nil
            let meta = Meta(scrolledUp: styled.scrolledUp, history: styled.history, find: Self.found(w.find, in: styled))
            let metaChanged = meta != w.sentMeta
            w.sentMeta = meta
            watches[id] = w
            guard full || !changed.isEmpty || metaChanged else { return }
            let message = TerminalScreen(terminalID: w.terminalID, columns: styled.columns, rows: styled.rows,
                                         cursorX: styled.cursorX, cursorY: styled.cursorY,
                                         foreground: iterm.palette.foreground, background: iterm.palette.background,
                                         lines: changed, full: full, scrolledUp: meta.scrolledUp, history: meta.history,
                                         find: meta.find)
            server.send(StreamMessage(kind: .terminalScreen, timestamp: Date().timeIntervalSince1970, isKeyframe: false,
                                      payload: Wire.encode(message)), to: w.connection)
            return
        }
        guard let screen = read(w.terminalID, windowID: w.windowID) else { return }
        let full = w.lines.isEmpty || screen.columns != w.columns || screen.rows != w.rows
        var changed: [TerminalLine] = []
        for (row, text) in screen.lines.enumerated() where full || row >= w.lines.count || w.lines[row] != text {
            changed.append(TerminalLine(row: row, runs: [TerminalRun(text: text)]))
        }
        w.lines = screen.lines; w.columns = screen.columns; w.rows = screen.rows
        watches[id] = w
        guard full || !changed.isEmpty else { return }
        let message = TerminalScreen(terminalID: w.terminalID, columns: screen.columns, rows: screen.rows, cursorX: 0, cursorY: -1,
                                     foreground: 0xD7DEE6, background: 0x0A0F14, lines: changed, full: full)
        server.send(StreamMessage(kind: .terminalScreen, timestamp: Date().timeIntervalSince1970, isKeyframe: false,
                                  payload: Wire.encode(message)), to: w.connection)
    }

    /// The find as the device draws it: how many matches, which is shown, and those on this screen.
    static func found(_ find: Find?, in screen: PortholeITermScreen.Screen) -> TerminalFind? {
        guard let find else { return nil }
        let length = find.query.count
        let hits = find.matches.enumerated().compactMap { i, m -> TerminalFindHit? in
            let row = m.line - screen.first
            guard row >= 0, row < screen.rows else { return nil }
            return TerminalFindHit(row: row, column: m.column, length: length, current: i == find.index)
        }
        return TerminalFind(query: find.query, count: find.matches.count, index: find.matches.isEmpty ? 0 : find.index + 1, hits: hits)
    }

    /// The session's visible screen: its size, and its last `rows` lines of text, each cut to `columns`.
    private func read(_ terminalID: String, windowID: UInt32?) -> (columns: Int, rows: Int, lines: [String])? {
        guard let text = osa.call("screenof", [String(windowID ?? 0), terminalID]), !text.isEmpty else { return nil }
        return PortholeScreenText.parse(text)
    }

    // MARK: Writing

    private func flush(_ terminalID: String) {
        guard let p = pending.removeValue(forKey: terminalID), !p.text.isEmpty else { return }
        // Porthole (22 Oct, "the keyboard seems to lag a bit"): through iTerm's API, a few ms; AppleScript's
        // write took ~50 ms a key, and stays the way when the helper isn't there.
        if !iterm.type(p.text, into: terminalID) {
            _ = osa.call("typeinto", [String(p.windowID ?? 0), terminalID, p.text])
        }
        // Show the echo now rather than at the next refresh, and again as Claude Code draws it a frame or two
        // later (the quarter-second timer alone made a key's echo wait for it).
        for (id, w) in watches where w.terminalID == terminalID { refresh(id) }
        for delay in [0.04, 0.12] {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                for (id, w) in self.watches where w.terminalID == terminalID { self.refresh(id) }
            }
        }
    }
}

/// The host's line to PortholeOSAHelper, which runs Porthole's AppleScript on its own main thread. `call`
/// sends one request and waits at most `timeout` for its answer; a late answer restarts the helper, so a
/// hung iTerm2 costs one call, never the host. Safe from any queue (one call at a time).
final class PortholeOSA: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var nextID = 1
    private let answers = AnswerBuffer()

    private final class AnswerBuffer: @unchecked Sendable {
        let lock = NSLock()
        let ready = DispatchSemaphore(value: 0)
        var pending = Data()
        var lines: [Data] = []
        func append(_ data: Data) {
            lock.lock()
            pending.append(data)
            var count = 0
            while let nl = pending.firstIndex(of: 0x0A) {
                lines.append(Data(pending[pending.startIndex..<nl]))
                pending = Data(pending[(nl + 1)...])
                count += 1
            }
            lock.unlock()
            for _ in 0..<count { ready.signal() }
        }
        func next() -> Data? {
            lock.lock(); defer { lock.unlock() }
            return lines.isEmpty ? nil : lines.removeFirst()
        }
    }

    private struct Answer: Decodable { let id: Int; let ok: Bool; let result: String? }

    /// The helper sits next to the host's executable (`swift build` puts both in .build/<config>/;
    /// Scripts/make-app.sh copies it into the app's Contents/MacOS).
    static var helperURL: URL? {
        let url = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .deletingLastPathComponent().appendingPathComponent("PortholeOSAHelper")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    func call(_ handler: String, _ args: [String], timeout: TimeInterval = 6) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard ensureRunning(), let input else { return nil }
        let id = nextID
        nextID += 1
        guard let body = try? JSONSerialization.data(withJSONObject: ["id": id, "handler": handler, "args": args]) else { return nil }
        do { try input.write(contentsOf: body + Data([0x0A])) } catch { stop(); return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 || answers.ready.wait(timeout: .now() + left) == .timedOut {
                print("Porthole: the AppleScript helper did not answer \(handler) within \(Int(timeout)) s; restarting it")
                stop()
                return nil
            }
            // Answers to calls that timed out earlier are skipped.
            guard let line = answers.next(), let answer = try? JSONDecoder().decode(Answer.self, from: line), answer.id == id else { continue }
            return answer.ok ? answer.result : nil
        }
    }

    private func ensureRunning() -> Bool {
        if let process, process.isRunning { return true }
        guard let url = Self.helperURL else {
            print("Porthole: PortholeOSAHelper is missing beside the host; the terminal view can't read iTerm")
            return false
        }
        let p = Process()
        p.executableURL = url
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        let buffer = answers
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { buffer.append(data) }
        }
        do { try p.run() } catch { print("Porthole: could not start PortholeOSAHelper: \(error)"); return false }
        process = p
        input = stdin.fileHandleForWriting
        return true
    }

    private func stop() {
        process?.terminate()
        process = nil
        input = nil
    }

    deinit { process?.terminate() }
}
