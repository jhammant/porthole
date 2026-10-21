import Foundation
import Network
import StreamProtocol
import SwiftTerm

/// Porthole (docs/agent-view-plan.md, phase 1): Claude Code's agent view for a device, as text. The device
/// asks for the terminal `agent-view` (kind 205, sized to its pane); the host runs `claude agents` in a
/// pseudo terminal of that size, reads it through a terminal emulator (SwiftTerm), and sends the screen as
/// kind 206, each cell in its own colour (iTerm's palette for the 256 indexed ones), only the lines that
/// changed. Keys (kind 207) go to the agent view as typed. One per device; it ends when the device stops
/// watching, picks another terminal, or leaves.
final class PortholeAgentViews: @unchecked Sendable {
    /// The terminal id a device watches for the agent view; never an iTerm session's (theirs are UUIDs).
    static let terminalID = "agent-view"

    private let server: StreamServer
    private let queue = DispatchQueue(label: "porthole.agentview", qos: .userInitiated)
    private var views: [ObjectIdentifier: PortholeAgentView] = [:]

    init(server: StreamServer) { self.server = server }

    /// A device's request for the agent view: start it at the pane's size, resize it, or stop it.
    func watch(_ request: TerminalRequest, from connection: NWConnection) {
        queue.async {
            let id = ObjectIdentifier(connection)
            if request.stop == true || request.terminalID != Self.terminalID {
                self.views.removeValue(forKey: id)?.end()
                return
            }
            let columns = min(max(request.fitColumns ?? 120, 20), 400), rows = min(max(request.fitRows ?? 40, 6), 200)
            if let view = self.views[id], view.running {
                view.setColours(request.colours)
                view.resize(columns: columns, rows: rows)
                return
            }
            self.views[id]?.end()
            let server = self.server
            let view = PortholeAgentView(columns: columns, rows: rows, colours: request.colours, queue: self.queue) { screen in
                server.send(PortholeHost.message(.terminalScreen, screen), to: connection)
            }
            self.views[id] = view
            view.start()
        }
    }

    func input(_ input: TerminalInput, from connection: NWConnection) {
        queue.async { self.views[ObjectIdentifier(connection)]?.write(input.text) }
    }

    /// Whether this device is watching the agent view (its keys come here, not to an iTerm session).
    func isWatching(_ connection: NWConnection) -> Bool {
        queue.sync { views[ObjectIdentifier(connection)] != nil }
    }

    func clientLeft(_ connection: NWConnection) {
        queue.async { self.views.removeValue(forKey: ObjectIdentifier(connection))?.end() }
    }

    func endAll() {
        queue.sync {
            views.values.forEach { $0.end() }
            views.removeAll()
        }
    }
}

/// One device's agent view: the process, the emulator and what the device was last sent. Everything on
/// the owner's queue.
final class PortholeAgentView: TerminalDelegate, LocalProcessDelegate {
    private let queue: DispatchQueue
    private let send: (TerminalScreen) -> Void
    private var terminal: Terminal!
    private var process: LocalProcess!
    private var palette: PortholeTermPalette
    private var columns: Int
    private var rows: Int
    /// What the device has, row by row; nil until the first (full) screen.
    private var sent: [[TerminalRun]]?
    private var flushScheduled = false
    private var cursorShown = true
    private(set) var running = false

    init(columns: Int, rows: Int, colours: String?, queue: DispatchQueue, send: @escaping (TerminalScreen) -> Void) {
        self.columns = columns; self.rows = rows; self.queue = queue; self.send = send
        self.palette = PortholeTermPalette.iTerm(colours)
        terminal = Terminal(delegate: self, options: TerminalOptions(cols: columns, rows: rows, scrollback: 0))
        process = LocalProcess(delegate: self, dispatchQueue: queue)
    }

    func start() {
        guard let claude = PortholeSessions.findClaude() else {
            terminal.feed(text: "Porthole: Claude Code's `claude` was not found on this Mac.\r\n")
            flush()
            return
        }
        running = true
        let home = NSHomeDirectory()
        process.startProcess(executable: claude, args: ["agents"], environment: Self.environment(home: home),
                             execName: "claude", currentDirectory: home + "/dev")
        print("Porthole: agent view started, \(columns)×\(rows)")
    }

    func resize(columns: Int, rows: Int) {
        guard columns != self.columns || rows != self.rows else { sent = nil; scheduleFlush(); return }
        self.columns = columns; self.rows = rows
        terminal.resize(cols: columns, rows: rows)
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
        if process.childfd >= 0 { _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size) }
        sent = nil   // the whole screen again, at the new size
        scheduleFlush()
    }

    /// Another colour set: the whole screen again in it.
    func setColours(_ colours: String?) {
        let next = PortholeTermPalette.iTerm(colours)
        guard next.background != palette.background || next.foreground != palette.foreground else { return }
        palette = next
        sent = nil
        scheduleFlush()
    }

    func write(_ text: String) {
        guard running else { return }
        process.send(data: ArraySlice(Array(text.utf8)))
    }

    func end() {
        guard running else { return }
        running = false
        process.terminate()
        print("Porthole: agent view ended")
    }

    /// The menu bar app's environment comes from launchd: a short PATH and no TERM. `claude` needs its own
    /// folder on the PATH (for the tools it runs) and a terminal that says it does 24-bit colour.
    static func environment(home: String) -> [String] {
        var env = ProcessInfo.processInfo.environment
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let path = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        env["PATH"] = (extra + path.filter { !extra.contains($0) }).joined(separator: ":")
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_GB.UTF-8"
        env["HOME"] = home
        return env.map { "\($0.key)=\($0.value)" }
    }

    // MARK: The screen

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        // About 30 times a second at most: Claude redraws in bursts, and one screen per burst is enough.
        queue.asyncAfter(deadline: .now() + 0.033) { [weak self] in
            self?.flushScheduled = false
            self?.flush()
        }
    }

    private func flush() {
        var lines: [[TerminalRun]] = []
        for row in 0..<rows { lines.append(runs(row: row)) }
        let full = sent == nil || sent?.count != lines.count
        var changed: [TerminalLine] = []
        for (row, runs) in lines.enumerated() where full || sent?[row] != runs {
            changed.append(TerminalLine(row: row, runs: runs))
        }
        let cursor = terminal.getCursorLocation()
        sent = lines
        send(TerminalScreen(terminalID: PortholeAgentViews.terminalID, columns: columns, rows: rows,
                            cursorX: cursorShown ? cursor.x : -1, cursorY: cursorShown ? cursor.y : -1,
                            foreground: palette.foreground, background: palette.background, lines: changed, full: full))
    }

    /// One row as runs of cells that share a style; a wide character's second cell is skipped (the
    /// device draws the character two cells wide).
    private func runs(row: Int) -> [TerminalRun] {
        guard let line = terminal.getLine(row: row) else { return [] }
        var runs: [TerminalRun] = []
        var text = "", key: (fg: UInt32?, bg: UInt32?, style: UInt8)? = nil
        for col in 0..<min(columns, line.count) {
            let cell = line[col]
            if cell.width == 0 { continue }
            let a = cell.attribute
            let style = Self.style(a.style)
            let k = (fg: palette.rgb(a.fg, isForeground: true), bg: palette.rgb(a.bg, isForeground: false), style: style)
            var ch = cell.getCharacter()
            if ch == "\u{0}" || a.style.contains(.invisible) { ch = " " }
            if let key, key.fg == k.fg, key.bg == k.bg, key.style == k.style {
                text.append(ch)
            } else {
                if let key, !text.isEmpty { runs.append(TerminalRun(text: text, fg: key.fg, bg: key.bg, style: key.style == 0 ? nil : key.style)) }
                key = k
                text = String(ch)
            }
        }
        if let key, !text.isEmpty {
            // Trailing default spaces carry nothing: the device fills the rest of the row with the background.
            let trimmed = (key.fg == nil && key.bg == nil && key.style == 0) ? String(text.reversed().drop(while: { $0 == " " }).reversed()) : text
            if !trimmed.isEmpty { runs.append(TerminalRun(text: trimmed, fg: key.fg, bg: key.bg, style: key.style == 0 ? nil : key.style)) }
        }
        return runs
    }

    /// SwiftTerm's style as the wire's flags: 1 bold, 2 italic, 4 underline, 8 inverse, 16 faint, 32 strikethrough.
    static func style(_ s: CharacterStyle) -> UInt8 {
        var f: UInt8 = 0
        if s.contains(.bold) { f |= 1 }
        if s.contains(.italic) { f |= 2 }
        if s.contains(.underline) { f |= 4 }
        if s.contains(.inverse) { f |= 8 }
        if s.contains(.dim) { f |= 16 }
        if s.contains(.crossedOut) { f |= 32 }
        return f
    }

    // MARK: TerminalDelegate

    /// The emulator's answers to Claude's queries (where the cursor is, what the terminal is) go back to it.
    func send(source: Terminal, data: ArraySlice<UInt8>) {
        if running { process.send(data: data) }
    }
    func showCursor(source: Terminal) { cursorShown = true; scheduleFlush() }
    func hideCursor(source: Terminal) { cursorShown = false; scheduleFlush() }
    func scrolled(source: Terminal, yDisp: Int) {}
    func setTerminalTitle(source: Terminal, title: String) {}
    func sizeChanged(source: Terminal) {}

    // MARK: LocalProcessDelegate

    func dataReceived(slice: ArraySlice<UInt8>) {
        terminal.feed(buffer: slice)
        scheduleFlush()
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        guard running else { return }
        running = false
        terminal.feed(text: "\r\n\u{1b}[2mThe agent view closed. Pick Agent view again to reopen it.\u{1b}[0m\r\n")
        flush()
        print("Porthole: agent view exited (\(exitCode.map(String.init) ?? "signal"))")
    }

    func getWindowSize() -> winsize {
        winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
    }
}

/// The terminal's colours as Jon's iTerm draws them: its default profile's foreground, background and 16
/// ANSI colours, then xterm's 6×6×6 cube and grey ramp for 16–255. Read once per agent view.
struct PortholeTermPalette: Equatable {
    var foreground: UInt32 = 0xC7C7C7
    var background: UInt32 = 0x000000
    var ansi: [UInt32] = [0x000000, 0xC91B00, 0x00C200, 0xC7C400, 0x0225C7, 0xCA30C7, 0x00C5C7, 0xC7C7C7,
                          0x686868, 0xFF6E67, 0x5FFA68, 0xFFFC67, 0x6871FF, 0xFF77FF, 0x60FDFF, 0xFFFFFF]

    /// The wire's colour for a cell's: nil for the default (the device uses the screen's own).
    func rgb(_ c: Attribute.Color, isForeground: Bool) -> UInt32? {
        switch c {
        case .defaultColor, .defaultInvertedColor: return nil
        case .trueColor(let r, let g, let b): return UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
        case .ansi256(let code): return indexed(Int(code))
        }
    }

    func indexed(_ i: Int) -> UInt32 {
        if i < 16 { return ansi[i] }
        if i < 232 {
            let n = i - 16, steps: [UInt32] = [0, 95, 135, 175, 215, 255]
            return steps[n / 36] << 16 | steps[(n / 6) % 6] << 8 | steps[n % 6]
        }
        let v = UInt32(8 + (i - 232) * 10)
        return v << 16 | v << 8 | v
    }

    /// iTerm's default profile, or xterm's colours where it has none. `colours`: "dark" or "light" picks that
    /// set of a profile with separate light and dark colours; nil follows the Mac's appearance, as iTerm does.
    static func iTerm(_ colours: String? = nil) -> PortholeTermPalette {
        var p = PortholeTermPalette()
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Preferences/com.googlecode.iterm2.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let profiles = plist["New Bookmarks"] as? [[String: Any]] else { return p }
        let guid = plist["Default Bookmark Guid"] as? String
        guard let profile = profiles.first(where: { $0["Guid"] as? String == guid }) ?? profiles.first else { return p }
        // A profile with separate light and dark colours (Jon's: Solarized) keeps each set under its own
        // keys, "Background Color (Dark)"; the Mac's appearance picks the set, as iTerm does.
        let dark = colours.map { $0 == "dark" } ?? (UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark")
        let suffix = profile["Use Separate Colors for Light and Dark Mode"] as? Bool == true ? (dark ? " (Dark)" : " (Light)") : ""
        func colour(_ name: String) -> UInt32? {
            guard let d = (profile[name + suffix] ?? profile[name]) as? [String: Any], let r = d["Red Component"] as? Double,
                  let g = d["Green Component"] as? Double, let b = d["Blue Component"] as? Double else { return nil }
            func byte(_ x: Double) -> UInt32 { UInt32(max(0, min(255, (x * 255).rounded()))) }
            return byte(r) << 16 | byte(g) << 8 | byte(b)
        }
        if let c = colour("Foreground Color") { p.foreground = c }
        if let c = colour("Background Color") { p.background = c }
        for i in 0..<16 { if let c = colour("Ansi \(i) Color") { p.ansi[i] = c } }
        return p
    }
}
