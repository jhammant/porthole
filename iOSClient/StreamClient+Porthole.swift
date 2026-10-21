import Foundation
import StreamProtocol

/// Porthole (docs/porthole-plan.md, iPad side): the Claude Code sessions on the Mac, as the device
/// holds them. The host sends the session list (kind 200) on connect and whenever it changes, the
/// watched session's transcript (202), and the answers to replies (204). Everything here runs on the
/// main queue (StreamClient's `handle` hops there first).
struct PortholeModel {
    var sessions: [ClaudeSession] = []
    /// The session whose transcript the device follows, and its entries, oldest first.
    var watching: String?
    var transcript: [TranscriptEntry] = []
    var transcriptTitle: String?
    /// Set when the connection drops while a session is watched: the next session list resumes it
    /// from the last entry the device has (`after`), so only what was missed comes back.
    var resumeOnNextList = false
    /// The latest answer to each reply, by token (a held reply gets two: queued, then typed).
    var results: [Int: ReplyResult] = [:]
    var nextToken = 1
    /// The watched terminals' screens (kind 206) by terminal id: an iTerm session's and the agent view's can
    /// show side by side (docs/agent-view-plan.md). Each pane showing one counts in `terminalPanes`.
    var terminals: [String: PortholeTerminalState] = [:]
    var terminalPanes: [String: Int] = [:]
    /// What the Mac says the person should know (kind 210), e.g. screen capture refused.
    var notice: PortholeNotice?
    /// Chrome's windows and tabs (kind 208).
    var browserTabs: BrowserTabs?
    /// The Mac's windows front to back, from the last session list.
    var macOrder: [UInt32] = []
    /// Windows shown on this device, most recent first: what Jon last looked at here leads.
    var recentPicks: [UInt32] = []
    /// What was on screen, sessions and windows alike, most recent first: ⌃⌥Tab flips to the second.
    var history: [PortholeHistoryItem] = []
    /// The same, in the order it came on screen, with a place in it: ⌃⌥← and ⌃⌥→ (PortholeBackForward).
    var backForward = PortholeBackForward<PortholeHistoryItem>()

    mutating func remember(_ item: PortholeHistoryItem) {
        backForward.visit(item)
        history.removeAll { $0 == item }
        history.insert(item, at: 0)
        if history.count > 32 { history.removeLast(history.count - 32) }
    }

    static let keep = 600

    func session(_ id: String?) -> ClaudeSession? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    var needsYou: [ClaudeSession] { sessions.filter { $0.state == .needsYou } }

    /// The next (or previous) session in the sidebar's order after `id`, wrapping round.
    func session(after id: String?, by step: Int) -> ClaudeSession? {
        guard !sessions.isEmpty else { return nil }
        guard let id, let i = sessions.firstIndex(where: { $0.id == id }) else { return step >= 0 ? sessions.first : sessions.last }
        let n = sessions.count
        return sessions[((i + step) % n + n) % n]
    }

    /// The next session that needs Jon after `id` (the longest wait first), wrapping round.
    func nextNeedingYou(after id: String?) -> ClaudeSession? {
        let list = needsYou
        guard !list.isEmpty else { return nil }
        guard let id, let i = list.firstIndex(where: { $0.id == id }) else { return list.first }
        return list[(i + 1) % list.count]
    }
}

extension StreamClient {
    /// A Porthole message from the host, on the main queue.
    func receivePorthole(_ kind: StreamMessageKind, _ data: Data) {
        switch kind {
        case .claudeSessions:
            guard let list = Wire.decode(SessionList.self, from: data) else { return }
            porthole.sessions = list.sessions
            if let order = list.windowOrder { porthole.macOrder = order }
            if porthole.resumeOnNextList, let id = porthole.watching {
                porthole.resumeOnNextList = false
                send(.watchTranscript, payload: Wire.encode(TranscriptRequest(sessionID: id, after: porthole.transcript.last?.seq)))
            }
        case .transcript:
            guard let chunk = Wire.decode(TranscriptChunk.self, from: data), chunk.sessionID == porthole.watching else { return }
            if chunk.reset {
                porthole.transcript = chunk.entries
            } else {
                let last = porthole.transcript.last?.seq ?? 0
                porthole.transcript += chunk.entries.filter { $0.seq > last }
            }
            if porthole.transcript.count > PortholeModel.keep {
                porthole.transcript.removeFirst(porthole.transcript.count - PortholeModel.keep)
            }
            if let title = chunk.title { porthole.transcriptTitle = title }
        case .replyResult:
            guard let result = Wire.decode(ReplyResult.self, from: data) else { return }
            porthole.results[result.token] = result
        case .portholeNotice:
            if let n = Wire.decode(PortholeNotice.self, from: data) { porthole.notice = n.text == nil ? nil : n }
        case .browserTabs:
            if let tabs = Wire.decode(BrowserTabs.self, from: data) { porthole.browserTabs = tabs }
        case .terminalScreen:
            guard let screen = Wire.decode(TerminalScreen.self, from: data), porthole.terminalPanes[screen.terminalID] != nil else { return }
            var state = porthole.terminals[screen.terminalID] ?? PortholeTerminalState(id: screen.terminalID, columns: screen.columns, rows: screen.rows, lines: [])
            if screen.full || state.id != screen.terminalID || state.rows != screen.rows {
                state = PortholeTerminalState(id: screen.terminalID, columns: screen.columns, rows: screen.rows,
                                              lines: Array(repeating: "", count: screen.rows))
                state.runs = Array(repeating: [], count: screen.rows)
            }
            state.columns = screen.columns
            state.cursor = (screen.cursorX >= 0 && screen.cursorY >= 0) ? PortholeTerminalState.Cell(x: screen.cursorX, y: screen.cursorY) : nil
            state.foreground = screen.foreground
            state.background = screen.background
            for line in screen.lines where line.row >= 0 && line.row < state.lines.count {
                state.lines[line.row] = line.runs.map(\.text).joined()
                state.runs[line.row] = line.runs
            }
            state.version &+= 1
            porthole.terminals[screen.terminalID] = state
        default:
            break
        }
    }

    /// Follow one session's transcript (the one shown); nil stops following.
    func watchSession(_ id: String?) {
        if let old = porthole.watching, old != id {
            send(.watchTranscript, payload: Wire.encode(TranscriptRequest(sessionID: old, stop: true)))
        }
        guard let id else {
            porthole.watching = nil
            porthole.transcript = []
            porthole.transcriptTitle = nil
            return
        }
        if porthole.watching != id {
            porthole.transcript = []
            porthole.transcriptTitle = porthole.session(id)?.title
        }
        porthole.watching = id
        send(.watchTranscript, payload: Wire.encode(TranscriptRequest(sessionID: id)))
    }

    /// Text for a session: typed into its prompt and submitted (held by the host while Claude works).
    /// Returns the token its ReplyResult will carry.
    @discardableResult
    func reply(_ text: String, to sessionID: String) -> Int {
        let token = porthole.nextToken
        porthole.nextToken += 1
        send(.sessionReply, payload: Wire.encode(SessionReply(sessionID: sessionID, text: text, token: token)))
        return token
    }

    /// A key for a session: Esc interrupts Claude, a number picks one of a question's options.
    @discardableResult
    func press(_ key: SessionReply.Key, in sessionID: String) -> Int {
        let token = porthole.nextToken
        porthole.nextToken += 1
        send(.sessionReply, payload: Wire.encode(SessionReply(sessionID: sessionID, key: key, token: token)))
        return token
    }

    /// Porthole's windows in recent order: those shown on this device most recently, then the Mac's front to
    /// back order, then the rest as Porthole lists them.
    var recentWindows: [WindowInfo] {
        let byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<UInt32>()
        var out: [WindowInfo] = []
        for id in porthole.recentPicks + porthole.macOrder + windows.map(\.id) where !seen.contains(id) {
            if let w = byID[id] { out.append(w); seen.insert(id) }
        }
        return out
    }

    /// Brings a Chrome tab forward on the Mac and streams its window.
    func open(tab: BrowserTab, in window: BrowserWindow) {
        send(.activateTab, payload: Wire.encode(ActivateTab(windowID: window.id, tabID: tab.id)))
        if window.id != 0 { show(window: window.id) }
    }

    /// Streams a window and remembers it as the most recent here.
    /// `remember` false: a session's window, which the session's own history entry stands for.
    func show(window id: UInt32, remember: Bool = true) {
        if remember { porthole.remember(.window(id)) }
        porthole.recentPicks.removeAll { $0 == id }
        porthole.recentPicks.insert(id, at: 0)
        if porthole.recentPicks.count > 64 { porthole.recentPicks.removeLast(porthole.recentPicks.count - 64) }
        select(.window(id))
    }

    /// A pane shows this terminal (an iTerm session's, or the agent view's): its screens are kept from now
    /// on. The host follows one iTerm session per device, and the agent view beside it, so another session's
    /// pane replaces the last session's.
    func openTerminalPane(_ terminalID: String) {
        if terminalID != PortholeShell.agentViewID {
            for old in porthole.terminalPanes.keys where old != terminalID && old != PortholeShell.agentViewID { stopTerminal(old) }
        }
        porthole.terminalPanes[terminalID, default: 0] += 1
    }

    /// A pane showing it went; the last one stops the host following it.
    func closeTerminalPane(_ terminalID: String) {
        guard let n = porthole.terminalPanes[terminalID] else { return }
        if n > 1 { porthole.terminalPanes[terminalID] = n - 1 } else { stopTerminal(terminalID) }
    }

    private func stopTerminal(_ terminalID: String) {
        porthole.terminalPanes[terminalID] = nil
        porthole.terminals[terminalID] = nil
        send(.watchTerminal, payload: Wire.encode(TerminalRequest(terminalID: terminalID, stop: true)))
    }

    /// Follow a terminal at the pane's size (again when the pane changes size).
    func watchTerminal(_ terminalID: String, windowID: UInt32?, fit: (columns: Int, rows: Int)? = nil) {
        guard porthole.terminalPanes[terminalID] != nil else { return }
        if demo {
            porthole.terminals[terminalID] = PortholeDemo.screen(terminalID, columns: fit?.columns ?? 100, rows: fit?.rows ?? 40)
            return
        }
        send(.watchTerminal, payload: Wire.encode(TerminalRequest(terminalID: terminalID, windowID: windowID,
                                                                   fitColumns: fit?.columns, fitRows: fit?.rows,
                                                                   colours: Self.textColours)))
    }

    /// Text in dark or light colours (the sidebar's Text colours; dark unless Jon picks light, 21 Oct).
    static let textColoursKey = "Porthole.textColours"
    static var textColours: String { UserDefaults.standard.string(forKey: textColoursKey) ?? "dark" }

    /// Porthole Anywhere: this device's push token and subscription, for the Mac (kind 212). Never from the demo.
    func sendPushRegistration(_ r: PushRegistration) {
        guard connected, !demo else { return }
        send(.pushRegistration, payload: Wire.encode(r))
    }

    /// Porthole: the Desktop streams this screen from now on (kind 211), and comes on screen if it wasn't.
    func pickDisplay(_ id: UInt32) {
        send(.pickDisplay, payload: Wire.encode(PickDisplay(displayID: id)))
        if active != .desktop { select(.desktop) }
    }

    /// Bytes for the watched terminal, as typed.
    func sendTerminal(_ text: String, to terminalID: String) {
        send(.terminalInput, payload: Wire.encode(TerminalInput(terminalID: terminalID, text: text)))
    }

    /// The connection ended: the list and answers go, the watched session stays on screen and resumes
    /// from its last entry once the next connection's list arrives.
    func resetPorthole() {
        porthole.sessions = []
        porthole.results = [:]
        porthole.resumeOnNextList = porthole.watching != nil
        porthole.terminals = [:]
        porthole.terminalPanes = [:]
    }
}

enum PortholeHistoryItem: Equatable {
    case session(String)
    case window(UInt32)
}

struct PortholeTerminalState: Equatable {
    struct Cell: Equatable { var x: Int; var y: Int }
    let id: String
    var columns: Int
    var rows: Int
    var lines: [String]
    /// Each row as the host's styled runs, colours and all (the text modes, docs/agent-view-plan.md).
    var runs: [[TerminalRun]] = []
    /// Where the terminal's own cursor is; nil while it is hidden (Claude Code draws its own).
    var cursor: Cell?
    var foreground: UInt32 = 0xC7C7C7
    var background: UInt32 = 0x000000
    /// Bumped with every screen, so a view redraws once per screen.
    var version = 0
}
