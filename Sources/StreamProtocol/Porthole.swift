import CoreGraphics
import Foundation

// Porthole (docs/porthole-plan.md): Claude Code sessions, terminal screens and browser tabs beside Porthole's
// windows. Kinds 200–209 (StreamMessageKind); Porthole's own readers map them to `.unknown` and skip them.
// Everything here is small JSON; frames never go through it.

// MARK: - Sessions (kind 200)

/// One Claude Code session running on the Mac.
public struct ClaudeSession: Codable, Hashable, Identifiable, Sendable {
    /// What the session is doing, for the sidebar's dot and order (docs/porthole-plan.md, Session states).
    public enum State: String, Codable, Sendable {
        case working     // Claude is busy
        case needsYou    // Claude finished and asked something (a question, a choice, a permission)
        case done        // Claude finished and asked nothing
        case idle        // your turn was the last word, or there are no turns yet
    }

    /// The Claude Code session id (the transcript's file name).
    public var id: String
    /// Claude's title for the session, else the iTerm window's title, else its name.
    public var title: String
    /// The session's group, from its working folder (PortholeSessions.portal: the host's groups.json, else the folder under ~/dev).
    public var portal: String
    /// The working folder under the home folder: "dev/acme/api".
    public var folder: String
    public var state: State
    /// When the state began, seconds since 1970: how long it has waited.
    public var since: Double?
    /// The iTerm window showing it (a CGWindowID, the same as `WindowInfo.id`); nil for `claude --bg`.
    public var windowID: UInt32?
    /// iTerm's own window number (⌥⌘N on the Mac), for ⌃⌥N on the device; nil when unknown.
    public var windowNumber: Int?
    /// The iTerm session's unique id, for the terminal view; nil without a terminal.
    public var terminalID: String?
    /// The last thing Claude wrote, one line, at most `PortholeWire.previewLength` characters.
    public var preview: String?

    public init(id: String, title: String, portal: String, folder: String, state: State, since: Double? = nil,
                windowID: UInt32? = nil, windowNumber: Int? = nil, terminalID: String? = nil, preview: String? = nil) {
        self.id = id; self.title = title; self.portal = portal; self.folder = folder; self.state = state
        self.since = since; self.windowID = windowID; self.windowNumber = windowNumber
        self.terminalID = terminalID; self.preview = preview
    }
}

public struct SessionList: Codable, Sendable, Equatable {
    /// In the sidebar's order: needs you (longest wait first), done (newest first), working, idle.
    public var sessions: [ClaudeSession]
    /// The Mac's windows front to back (CGWindowIDs, on screen, normal level): recent use, which Porthole's
    /// own window list does not give (it keeps first-seen order). Nil from an older host.
    public var windowOrder: [UInt32]?
    public init(sessions: [ClaudeSession], windowOrder: [UInt32]? = nil) { self.sessions = sessions; self.windowOrder = windowOrder }
}

// MARK: - Transcript (kinds 201, 202)

/// Device → host: follow one session's transcript. A later request replaces the earlier one.
public struct TranscriptRequest: Codable, Sendable {
    public var sessionID: String
    /// Resume: only entries after this sequence number. Nil: the last `PortholeWire.transcriptLimit`.
    public var after: Int?
    /// True: stop following.
    public var stop: Bool?
    public init(sessionID: String, after: Int? = nil, stop: Bool? = nil) {
        self.sessionID = sessionID; self.after = after; self.stop = stop
    }
}

public struct TranscriptEntry: Codable, Hashable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable {
        case you        // your prompt
        case claude     // Claude's text (Markdown)
        case tool       // one tool use, one line: "Bash: Build the host"
        case question   // a pending choice: `text` is the question, `options` its answers
    }
    /// The entry's place in the session, from 1, stable for the life of the session's file.
    public var seq: Int
    public var id: Int { seq }
    public var role: Role
    public var text: String
    public var options: [String]?
    /// Seconds since 1970.
    public var at: Double?

    public init(seq: Int, role: Role, text: String, options: [String]? = nil, at: Double? = nil) {
        self.seq = seq; self.role = role; self.text = text; self.options = options; self.at = at
    }
}

public struct TranscriptChunk: Codable, Sendable {
    public var sessionID: String
    public var title: String?
    public var entries: [TranscriptEntry]
    /// True: these replace whatever the device holds for the session (a new subscription, or the file
    /// was rewritten). False: they follow on from the last entry it has.
    public var reset: Bool
    public init(sessionID: String, title: String?, entries: [TranscriptEntry], reset: Bool) {
        self.sessionID = sessionID; self.title = title; self.entries = entries; self.reset = reset
    }
}

// MARK: - Replies (kinds 203, 204)

/// Device → host: something for a session to read. Exactly one of `text` and `key`.
public struct SessionReply: Codable, Sendable {
    /// Keys a reply may press instead of text: Esc interrupts Claude, a digit picks an option.
    public enum Key: String, Codable, Sendable {
        case esc, enter, up, down
        case option1, option2, option3, option4, option5, option6, option7, option8, option9
    }
    public var sessionID: String
    public var text: String?
    public var key: Key?
    /// Echoed in the ReplyResult.
    public var token: Int
    public init(sessionID: String, text: String? = nil, key: Key? = nil, token: Int) {
        self.sessionID = sessionID; self.text = text; self.key = key; self.token = token
    }
}

public struct ReplyResult: Codable, Sendable, Equatable {
    public var sessionID: String
    public var token: Int
    /// True once the reply was typed into the session.
    public var ok: Bool
    /// True: Claude was still working, so the host holds the reply and types it when Claude finishes
    /// (a second ReplyResult with the same token follows, `ok` true or false). Text typed as a turn
    /// ends can be lost (found 16 Oct in Scripts/porthole-e2e.py).
    public var queued: Bool?
    /// Why not, in a line for the person: "This session has no terminal window."
    public var reason: String?
    public init(sessionID: String, token: Int, ok: Bool, queued: Bool? = nil, reason: String? = nil) {
        self.sessionID = sessionID; self.token = token; self.ok = ok; self.queued = queued; self.reason = reason
    }
}

// MARK: - Terminal (kinds 205, 206, 207)

/// Device → host: follow one iTerm session's screen. A later request replaces the earlier one.
public struct TerminalRequest: Codable, Sendable {
    /// The iTerm session's unique id (`ClaudeSession.terminalID`).
    public var terminalID: String
    /// Its iTerm window (`ClaudeSession.windowID`), so the host finds the session in one step.
    public var windowID: UInt32?
    /// The columns and rows that fit the device's pane at its text size: the host sets the session to
    /// them while the device watches (Jon never uses the Mac at the same time) and puts the session's
    /// own size back after. Nil leaves the size alone.
    public var fitColumns: Int?
    public var fitRows: Int?
    public var stop: Bool?
    /// Porthole: "dark" or "light", the terminal profile's colour set the screen comes in (21 Oct: Jon's text
    /// came in day colours while his Mac was in light mode); nil follows the Mac's appearance.
    public var colours: String?
    public init(terminalID: String, windowID: UInt32? = nil, fitColumns: Int? = nil, fitRows: Int? = nil, stop: Bool? = nil,
                colours: String? = nil) {
        self.terminalID = terminalID; self.windowID = windowID; self.fitColumns = fitColumns; self.fitRows = fitRows; self.stop = stop
        self.colours = colours
    }
}

/// A run of cells that share one style.
public struct TerminalRun: Codable, Hashable, Sendable {
    public var text: String
    /// Colours as 0xRRGGBB; nil is the terminal's default.
    public var fg: UInt32?
    public var bg: UInt32?
    /// Bit flags: 1 bold, 2 italic, 4 underline, 8 inverse, 16 faint, 32 strikethrough.
    public var style: UInt8?
    public init(text: String, fg: UInt32? = nil, bg: UInt32? = nil, style: UInt8? = nil) {
        self.text = text; self.fg = fg; self.bg = bg; self.style = style
    }
}

public struct TerminalLine: Codable, Hashable, Sendable {
    public var row: Int
    public var runs: [TerminalRun]
    public init(row: Int, runs: [TerminalRun]) { self.row = row; self.runs = runs }
}

public struct TerminalScreen: Codable, Sendable {
    public var terminalID: String
    public var columns: Int
    public var rows: Int
    public var cursorX: Int
    public var cursorY: Int
    /// The terminal's default colours, 0xRRGGBB.
    public var foreground: UInt32
    public var background: UInt32
    /// The lines that changed; every line when `full`.
    public var lines: [TerminalLine]
    public var full: Bool
    public init(terminalID: String, columns: Int, rows: Int, cursorX: Int, cursorY: Int, foreground: UInt32,
                background: UInt32, lines: [TerminalLine], full: Bool) {
        self.terminalID = terminalID; self.columns = columns; self.rows = rows; self.cursorX = cursorX
        self.cursorY = cursorY; self.foreground = foreground; self.background = background
        self.lines = lines; self.full = full
    }
}

/// Device → host: what a terminal would send for the keys pressed (UTF-8, control characters
/// included: this is the keyboard).
public struct TerminalInput: Codable, Sendable {
    public var terminalID: String
    public var text: String
    public init(terminalID: String, text: String) { self.terminalID = terminalID; self.text = text }
}

// MARK: - Browser (kinds 208, 209)

public struct BrowserTab: Codable, Hashable, Identifiable, Sendable {
    /// Chrome's own tab id, stable while the tab lives.
    public var id: Int
    public var title: String
    public var url: String
    public var active: Bool
    public init(id: Int, title: String, url: String, active: Bool) {
        self.id = id; self.title = title; self.url = url; self.active = active
    }
}

public struct BrowserWindow: Codable, Hashable, Identifiable, Sendable {
    /// The window's CGWindowID when matched to Porthole's list, else 0.
    public var id: UInt32
    public var tabs: [BrowserTab]
    public init(id: UInt32, tabs: [BrowserTab]) { self.id = id; self.tabs = tabs }
}

public struct BrowserTabs: Codable, Sendable, Equatable {
    public var bundleID: String
    public var windows: [BrowserWindow]
    public init(bundleID: String, windows: [BrowserWindow]) { self.bundleID = bundleID; self.windows = windows }
}

public struct ActivateTab: Codable, Sendable {
    public var windowID: UInt32
    public var tabID: Int
    public init(windowID: UInt32, tabID: Int) { self.windowID = windowID; self.tabID = tabID }
}

// MARK: - Notices (kind 210)

/// Host → device: something the person should know about the Mac, shown over the picture until cleared.
public struct PortholeNotice: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// Screen capture didn't start or stopped: often macOS waiting for Allow on its screen-recording
        /// prompt. Chat and Terminal don't capture the screen and keep working.
        case captureBlocked
    }
    public var kind: Kind
    /// Nil clears the notice.
    public var text: String?
    public init(kind: Kind, text: String?) { self.kind = kind; self.text = text }
}

// MARK: - Limits and rules shared by both ends

public enum PortholeWire {
    public static let transcriptLimit = 200
    public static let previewLength = 160
    public static let maxReplyCharacters = 8000
    public static let maxTerminalInput = 4096
    /// Replies (kind 203) and terminal input messages (kind 207) a device may send in one second.
    public static let repliesPerSecond = 4
    public static let terminalInputsPerSecond = 120
    /// How often the host reads a watched terminal's screen.
    public static let terminalRefreshSeconds: Double = 0.25
    /// How long the host holds a reply for a working session before giving up on it.
    public static let replyHoldSeconds: Double = 600
    /// The most windows a `.tiles` source takes.
    public static let maxTiles = 4

    /// A reply's text as it may reach a terminal: CRLF and CR become LF, control characters other
    /// than LF and tab are removed (an escape sequence in a reply could otherwise drive the terminal),
    /// the ends trimmed, and at most `maxReplyCharacters` characters kept. Nil when nothing is left.
    public static func sanitizedReply(_ text: String) -> String? {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var kept = String.UnicodeScalarView()
        for scalar in unified.unicodeScalars {
            if scalar == "\n" || scalar == "\t" { kept.append(scalar); continue }
            if scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value) { continue }
            // Bidirectional overrides and isolates make text read differently from what it does.
            if (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value) { continue }
            kept.append(scalar)
        }
        let trimmed = String(kept).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > maxReplyCharacters ? String(trimmed.prefix(maxReplyCharacters)) : trimmed
    }

    /// Frames for `.tiles` in a display of `size`, in the order of the source's windows: one or two
    /// windows sit side by side (one alone fills it), three or four make a 2×2 grid (with three, the
    /// last tile stays empty: a four-tile layout whose window closed). Each frame is inset by half of
    /// `gap`, so neighbours never touch.
    public static func tileFrames(count: Int, in size: CGSize, gap: CGFloat = 2) -> [CGRect] {
        guard count >= 1, size.width > 0, size.height > 0 else { return [] }
        if count == 1 { return [CGRect(origin: .zero, size: size)] }
        let w = (size.width / 2).rounded(.down), h = (size.height / 2).rounded(.down)
        let cells: [CGRect]
        if count == 2 {
            cells = [CGRect(x: 0, y: 0, width: w, height: size.height),
                     CGRect(x: w, y: 0, width: size.width - w, height: size.height)]
        } else {
            cells = [CGRect(x: 0, y: 0, width: w, height: h),
                     CGRect(x: w, y: 0, width: size.width - w, height: h),
                     CGRect(x: 0, y: h, width: w, height: size.height - h),
                     CGRect(x: w, y: h, width: size.width - w, height: size.height - h)]
        }
        return cells.map { $0.insetBy(dx: gap / 2, dy: gap / 2) }
    }
}
