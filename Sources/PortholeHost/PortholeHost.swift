import AppKit
import Foundation
import Network
import StreamProtocol

/// Porthole (docs/porthole-plan.md, Mac side): the Claude Code session feed for connected devices.
/// Every 2 s while a device is connected: the session list (kind 200, sent when it changes) and each
/// watched transcript's new entries (kind 202). Replies (kind 203) are typed into iTerm and answered
/// with kind 204.
///
/// Everything runs on one serial queue of its own, so a slow AppleScript call or a large transcript
/// never holds up the stream: the coordinator hands messages over, and the server sends from any queue.
final class PortholeHost: @unchecked Sendable {
    private let server: StreamServer
    private let queue = DispatchQueue(label: "porthole.feed", qos: .utility)
    private let sessions = PortholeSessions()
    /// Terminal screens and keys (kinds 205–207), on a queue of their own. Made with the host, not
    /// lazily: the coordinator's queue and this one both reach it.
    private let terminals: PortholeTerminalFeed
    /// Claude Code's agent view as text (docs/agent-view-plan.md): the terminal id `agent-view`.
    private let agentViews: PortholeAgentViews
    /// Porthole Anywhere: push notifications when a session needs you (PortholeAnywhereHost).
    private let anywhere = PortholeAnywhereHost()
    /// Chrome's tabs (kinds 208, 209), read through a helper of their own so a slow Chrome never holds up
    /// a terminal; every other tick (4 s).
    private let browserOSA = PortholeOSA()
    private var browser: PortholeBrowser.Snapshot?
    private var ticks = 0
    private var captureNoticeShown = false
    private var timer: DispatchSourceTimer?
    private var lastList: SessionList?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    private struct Watch {
        let connection: NWConnection
        let sessionID: String
        let file: PortholeTranscriptFile
        var title: String?
    }
    private var watches: [ObjectIdentifier: Watch] = [:]
    /// Sessions a device asked to follow before their transcript existed (a new session writes its
    /// file with its first prompt): looked for again every tick, then followed like any other.
    private var waiting: [ObjectIdentifier: (connection: NWConnection, request: TranscriptRequest)] = [:]
    private var replyTimes: [ObjectIdentifier: [CFAbsoluteTime]] = [:]
    /// Replies to a session Claude is still working in, typed when it finishes (oldest first).
    private struct Held { let reply: SessionReply; let connection: NWConnection; let since: CFAbsoluteTime }
    private var held: [Held] = []
    private var told: Set<String> = []

    static let interval: TimeInterval = 2

    init(server: StreamServer) {
        self.server = server
        self.terminals = PortholeTerminalFeed(server: server)
        self.agentViews = PortholeAgentViews(server: server)
    }

    // MARK: Devices

    /// A device's catalog went out: its session list follows, and the feed runs while any device is here.
    func clientJoined(_ connection: NWConnection) {
        queue.async {
            self.connections[ObjectIdentifier(connection)] = connection
            if self.timer == nil { self.start() }
            let t0 = CFAbsoluteTimeGetCurrent()
            let list = self.lastList ?? self.refreshList(broadcast: false)
            self.server.send(Self.message(.claudeSessions, list), to: connection)
            if self.browser == nil { self.browser = PortholeBrowser.snapshot(self.browserOSA) }
            if let tabs = self.browser?.tabs {
                self.server.send(Self.message(.browserTabs, tabs), to: connection)
                print("Porthole: Chrome, \(tabs.windows.count) windows and \(tabs.windows.reduce(0) { $0 + $1.tabs.count }) tabs → \(connection.endpoint)")
            } else {
                print("Porthole: no Chrome tabs to send (Chrome running: \(!NSRunningApplication.runningApplications(withBundleIdentifier: PortholeBrowser.bundleID).isEmpty))")
            }
            print(String(format: "Porthole: %d Claude Code sessions → %@ (%.0f ms)", list.sessions.count, "\(connection.endpoint)",
                         (CFAbsoluteTimeGetCurrent() - t0) * 1000))
        }
    }

    func clientLeft(_ connection: NWConnection) {
        queue.async {
            let id = ObjectIdentifier(connection)
            self.connections[id] = nil
            self.watches[id] = nil
            self.waiting[id] = nil
            self.replyTimes[id] = nil
            self.held.removeAll { ObjectIdentifier($0.connection) == id }
            if self.connections.isEmpty { self.stop() }
        }
        terminals.clientLeft(connection)
        agentViews.clientLeft(connection)
        anywhere.clientLeft(connection)
    }

    /// A Porthole message from an admitted device (the coordinator checks that first).
    func handle(_ message: StreamMessage, from connection: NWConnection) {
        // Timed on arrival, not when the queue gets to it: typing a reply takes a few hundred ms, and
        // the rate is about how fast a device sends.
        let arrived = CFAbsoluteTimeGetCurrent()
        // Terminal messages go straight to the terminal's queue, in the order the connection's other
        // events reach it: through this queue they could wait behind a slow session lookup and arrive
        // after the device had left, fitting a session for nobody (found 17 Oct).
        switch message.kind {
        case .watchTerminal:
            guard let request = Wire.decode(TerminalRequest.self, from: message.payload) else { return }
            if request.terminalID == PortholeAgentViews.terminalID { agentViews.watch(request, from: connection) }
            else { terminals.watch(request, from: connection) }
            return
        case .pushRegistration:
            if let r = Wire.decode(PushRegistration.self, from: message.payload) { anywhere.register(r, from: connection) }
            return
        case .terminalInput:
            guard let input = Wire.decode(TerminalInput.self, from: message.payload) else { return }
            if input.terminalID == PortholeAgentViews.terminalID { agentViews.input(input, from: connection) }
            else { terminals.input(input, from: connection, arrived: arrived) }
            return
        default:
            break
        }
        queue.async {
            switch message.kind {
            case .watchTranscript:
                guard let request = Wire.decode(TranscriptRequest.self, from: message.payload) else { return }
                self.watch(request, from: connection)
            case .sessionReply:
                guard let reply = Wire.decode(SessionReply.self, from: message.payload) else { return }
                self.reply(reply, from: connection, arrived: arrived)
            case .activateTab:
                guard let request = Wire.decode(ActivateTab.self, from: message.payload) else { return }
                if !PortholeBrowser.activate(request, in: self.browser, self.browserOSA) { print("Porthole: that Chrome tab wasn't found") }
                self.refreshTabs()
            default:
                break
            }
        }
    }

    /// Screen capture didn't start or stopped with an error: every device is told, in plain words.
    func captureProblem(_ error: Error) {
        let detail = (error as NSError).localizedDescription
        let text = "Your Mac couldn’t capture the screen (\(detail)). It may be waiting for Allow on a screen-recording prompt: click it on the Mac or through Jump Desktop. Chat and Terminal still work."
        server.broadcast(Self.message(.portholeNotice, PortholeNotice(kind: .captureBlocked, text: text)))
        captureNoticeShown = true
    }

    /// A stream started: a capture notice, if one showed, goes.
    func captureOK() {
        guard captureNoticeShown else { return }
        captureNoticeShown = false
        server.broadcast(Self.message(.portholeNotice, PortholeNotice(kind: .captureBlocked, text: nil)))
    }

    /// The host is stopping (main queue): terminals fitted to a device go back to their own size.
    func restoreForExit() {
        terminals.restoreAll()
        agentViews.endAll()
    }

    // MARK: The feed

    private func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func stop() {
        timer?.cancel()
        timer = nil
        lastList = nil
    }

    private func tick() {
        refreshList(broadcast: true)
        ticks += 1
        if ticks % 2 == 0 { refreshTabs() }
        for (_, w) in waiting where sessions.file(for: w.request.sessionID) != nil {
            watch(w.request, from: w.connection)
        }
        releaseHeld()
        for (id, w) in watches {
            let (added, reset) = w.file.readNew()
            if reset {
                send(chunk: w.file.model.entries, of: w, reset: true)
            } else if !added.isEmpty || w.file.model.title != w.title {
                send(chunk: added, of: w, reset: false)
            }
            watches[id]?.title = w.file.model.title
        }
    }

    /// Chrome's tabs again, sent to every device when they changed.
    private func refreshTabs() {
        let next = PortholeBrowser.snapshot(browserOSA)
        let changed = next?.tabs != browser?.tabs
        browser = next
        if changed, let tabs = next?.tabs { server.broadcast(Self.message(.browserTabs, tabs)) }
    }

    @discardableResult
    private func refreshList(broadcast: Bool) -> SessionList {
        let list = sessions.snapshot()
        if broadcast, list != lastList { server.broadcast(Self.message(.claudeSessions, list)) }
        lastList = list
        return list
    }

    // MARK: Transcripts

    private func watch(_ request: TranscriptRequest, from connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        if request.stop == true { watches[id] = nil; waiting[id] = nil; return }
        guard let url = sessions.file(for: request.sessionID) else {
            // No transcript yet: an empty one now, the real one once the file appears.
            watches[id] = nil
            waiting[id] = (connection, request)
            server.send(Self.message(.transcript, TranscriptChunk(sessionID: request.sessionID, title: nil, entries: [], reset: true)), to: connection)
            return
        }
        waiting[id] = nil
        // The same file as this device already follows: no need to read it again.
        let file: PortholeTranscriptFile
        if let current = watches[id], current.sessionID == request.sessionID {
            file = current.file
            _ = file.readNew()
        } else {
            // The last 2 MB: enough for the last couple of hundred entries, at once even for a 36 MB file.
            file = PortholeTranscriptFile(url: url, tailBytes: 2_000_000)
            _ = file.readNew()
        }
        let w = Watch(connection: connection, sessionID: request.sessionID, file: file, title: file.model.title)
        watches[id] = w
        let entries = file.model.entries
        if let after = request.after, let first = entries.first, after >= first.seq - 1, after <= file.model.seq {
            send(chunk: entries.filter { $0.seq > after }, of: w, reset: false)
        } else {
            send(chunk: Array(entries.suffix(PortholeWire.transcriptLimit)), of: w, reset: true)
        }
    }

    /// One chunk to the watching device, its oldest entries dropped until it fits the device's cap.
    private func send(chunk entries: [TranscriptEntry], of w: Watch, reset: Bool) {
        var entries = entries
        var payload = Wire.encode(TranscriptChunk(sessionID: w.sessionID, title: w.file.model.title, entries: entries, reset: reset))
        while payload.count > StreamMessage.maxOtherHostPayload - 4096, entries.count > 1 {
            entries.removeFirst(max(1, entries.count / 4))
            payload = Wire.encode(TranscriptChunk(sessionID: w.sessionID, title: w.file.model.title, entries: entries, reset: true))
        }
        server.send(StreamMessage(kind: .transcript, timestamp: Date().timeIntervalSince1970, isKeyframe: false, payload: payload), to: w.connection)
    }

    // MARK: Replies

    private func reply(_ reply: SessionReply, from connection: NWConnection, arrived: CFAbsoluteTime) {
        let id = ObjectIdentifier(connection)
        func answer(_ ok: Bool, _ reason: String? = nil) {
            server.send(Self.message(.replyResult, ReplyResult(sessionID: reply.sessionID, token: reply.token, ok: ok, reason: reason)), to: connection)
        }
        let now = arrived
        var recent = (replyTimes[id] ?? []).filter { now - $0 < 1 }
        guard recent.count < PortholeWire.repliesPerSecond else {
            replyTimes[id] = recent
            answer(false, "Too many replies at once. Try again.")
            return
        }
        recent.append(now)
        replyTimes[id] = recent
        guard let session = sessions.byID[reply.sessionID] else { answer(false, "That session has ended."); return }
        guard session.terminalID != nil else {
            answer(false, "This session has no terminal window, so it can’t take replies from here.")
            return
        }
        // Esc is for a working session (it interrupts); anything else waits for Claude to finish.
        if session.state == .working, reply.key != .esc {
            held.append(Held(reply: reply, connection: connection, since: now))
            server.send(Self.message(.replyResult, ReplyResult(sessionID: reply.sessionID, token: reply.token, ok: false, queued: true,
                                                                reason: "Sent when Claude finishes.")), to: connection)
            print("Porthole: reply to \(SafeText.label(session.title)) held until Claude finishes")
            return
        }
        type(reply, into: session, answering: connection)
    }

    /// Held replies whose session has finished its turn are typed now, oldest first; one held longer
    /// than `PortholeWire.replyHoldSeconds`, or whose session ended, is refused.
    private func releaseHeld() {
        guard !held.isEmpty else { return }
        let now = CFAbsoluteTimeGetCurrent()
        var keep: [Held] = []
        for h in held {
            guard let session = sessions.byID[h.reply.sessionID] else {
                server.send(Self.message(.replyResult, ReplyResult(sessionID: h.reply.sessionID, token: h.reply.token, ok: false,
                                                                    reason: "That session ended before Claude finished.")), to: h.connection)
                continue
            }
            if session.state == .working {
                if now - h.since > PortholeWire.replyHoldSeconds {
                    server.send(Self.message(.replyResult, ReplyResult(sessionID: h.reply.sessionID, token: h.reply.token, ok: false,
                                                                        reason: "Claude was still working after 10 minutes, so it wasn’t sent.")), to: h.connection)
                } else {
                    keep.append(h)
                }
                continue
            }
            type(h.reply, into: session, answering: h.connection)
        }
        held = keep
    }

    private func type(_ reply: SessionReply, into session: ClaudeSession, answering connection: NWConnection) {
        func answer(_ ok: Bool, _ reason: String? = nil) {
            server.send(Self.message(.replyResult, ReplyResult(sessionID: reply.sessionID, token: reply.token, ok: ok, reason: reason)), to: connection)
        }
        guard let terminal = session.terminalID else { answer(false, "This session has no terminal window."); return }
        let body: String, submit: Bool, what: String
        if let key = reply.key {
            body = PortholeITerm.bytes(for: key); submit = false; what = "the \(key.rawValue) key"
        } else if let raw = reply.text, let text = PortholeWire.sanitizedReply(raw) {
            (body, submit) = PortholeITerm.bytes(forReply: text); what = "\(text.count) characters"
        } else {
            answer(false, "There was nothing to send.")
            return
        }
        let failure = PortholeITerm.write(body, submit: submit, toSession: terminal)
        print("Porthole: reply to \(SafeText.label(session.title)), \(what): \(failure.map { "not typed (\($0))" } ?? "typed")")
        answer(failure == nil, failure)
        // The state changes as Claude starts on it: look again soon rather than at the next tick.
        queue.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refreshList(broadcast: true) }
    }

    static func message<T: Encodable>(_ kind: StreamMessageKind, _ value: T) -> StreamMessage {
        StreamMessage(kind: kind, timestamp: Date().timeIntervalSince1970, isKeyframe: false, payload: Wire.encode(value))
    }
}
