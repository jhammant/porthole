import Foundation
import StreamProtocol

/// Porthole (docs/porthole-plan.md, Mac side): one Claude Code session's transcript, read from its JSONL
/// file (`~/.claude/projects/<slug>/<sessionId>.jsonl`). Pure: lines in, entries, title and state out,
/// so Tests/checks/porthole-transcript can feed it lines.
///
/// Entries are your prompts, Claude's text, one line per tool use, and a pending `AskUserQuestion` as a
/// question with its options. Thinking, tool results, side chains (subagents) and bookkeeping records
/// are left out.
struct PortholeTranscript {
    /// The session's last word, which decides its state.
    enum Tail: Equatable {
        case nothing
        case you                    // your prompt (Claude busy on it, or the turn was interrupted)
        case claude(String)         // Claude's text, last in its turn
        case toolPending(String)    // a tool use still waiting for its result: a permission prompt or a question
        case toolDone               // the last tool use has its result and Claude has said nothing since
    }

    private(set) var entries: [TranscriptEntry] = []
    /// The session's name as Claude Code shows it: the one it was given (`custom-title`: /rename, or a
    /// name set for it), else Claude's own title (`ai-title`). Claude Code writes both again through the
    /// file, so a tail read has them; the ai-title alone named every renamed session wrongly (20 Oct).
    var title: String? { customTitle ?? aiTitle }
    private(set) var customTitle: String?
    private var aiTitle: String?
    /// The last entry's sequence number. Fed with each line's byte offset (`ingest(_:offset:)`), an entry's
    /// number is offset × 16 + its place in the line: stable for the life of the file and increasing,
    /// so a session can be read from its tail (a 36 MB transcript took over 14 s whole, 17 Oct) and a
    /// device can still resume after a number. Without offsets, entries count from 1.
    private(set) var seq = 0
    private var lineOffset: UInt64?
    private var placeInLine = 0
    private(set) var tail: Tail = .nothing
    /// When the tail was written, seconds since 1970.
    private(set) var tailAt: Double?
    private(set) var lastClaudeText: String?
    /// Tool uses waiting for a result: id → tool name.
    private var pending: [String: String] = [:]
    /// Entries kept in memory (the newest).
    let keep: Int

    init(keep: Int = 400) { self.keep = keep }

    // MARK: Reading

    /// Feeds one line of the file; returns the entries it added (none for most records).
    @discardableResult
    mutating func ingest(_ line: Data, offset: UInt64? = nil) -> [TranscriptEntry] {
        lineOffset = offset
        placeInLine = 0
        guard !line.isEmpty, let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return [] }
        let at = (record["timestamp"] as? String).flatMap(Self.date)
        switch record["type"] as? String {
        case "ai-title":
            if let t = (record["aiTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { aiTitle = t }
            return []
        case "custom-title":
            if let t = (record["customTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { customTitle = t }
            return []
        case "user":
            if record["isMeta"] as? Bool == true || record["isCompactSummary"] as? Bool == true
                || record["isSidechain"] as? Bool == true { return [] }
            guard let message = record["message"] as? [String: Any] else { return [] }
            if let text = message["content"] as? String { return you(text, at: at) }
            var added: [TranscriptEntry] = []
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "tool_result":
                    if let id = block["tool_use_id"] as? String, pending.removeValue(forKey: id) != nil,
                       pending.isEmpty, case .toolPending = tail {
                        tail = .toolDone; tailAt = at
                    }
                case "text":
                    added += you(block["text"] as? String ?? "", at: at)
                default:
                    break   // images and documents you attached
                }
            }
            return added
        case "assistant":
            if record["isSidechain"] as? Bool == true { return [] }
            guard let message = record["message"] as? [String: Any] else { return [] }
            var added: [TranscriptEntry] = []
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    lastClaudeText = text
                    tail = .claude(text); tailAt = at
                    added.append(add(.claude, text, at: at))
                case "tool_use":
                    let name = block["name"] as? String ?? "Tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    if let id = block["id"] as? String { pending[id] = name }
                    tail = .toolPending(name); tailAt = at
                    if name == "AskUserQuestion", let q = Self.question(input) {
                        added.append(add(.question, q.text, options: q.options, at: at))
                    } else {
                        added.append(add(.tool, Self.toolLine(name, input), at: at))
                    }
                default:
                    break   // thinking
                }
            }
            return added
        default:
            return []
        }
    }

    private mutating func you(_ raw: String, at: Double?) -> [TranscriptEntry] {
        guard let text = Self.prompt(raw) else { return [] }
        if text == Self.interrupted {
            // Your Esc: Claude stopped, nothing is pending any more.
            pending = [:]
            tail = .you; tailAt = at
            return [add(.tool, "Interrupted by you", at: at)]
        }
        tail = .you; tailAt = at
        return [add(.you, text, at: at)]
    }

    private mutating func add(_ role: TranscriptEntry.Role, _ text: String, options: [String]? = nil, at: Double?) -> TranscriptEntry {
        if let lineOffset {
            seq = Int(lineOffset) * 16 + min(placeInLine, 15)
            placeInLine += 1
        } else {
            seq += 1
        }
        let entry = TranscriptEntry(seq: seq, role: role, text: text, options: options, at: at)
        entries.append(entry)
        if entries.count > keep { entries.removeFirst(entries.count - keep) }
        return entry
    }

    // MARK: State

    /// The session's state for the sidebar, given whether `claude agents` says it is busy.
    func state(busy: Bool) -> ClaudeSession.State {
        if busy { return .working }
        switch tail {
        case .toolPending: return .needsYou
        case .claude(let text): return Self.asks(text) ? .needsYou : .done
        case .you, .nothing, .toolDone: return .idle
        }
    }

    /// Claude's last text as one line for the sidebar.
    var preview: String? {
        guard let text = lastClaudeText else { return nil }
        return Self.oneLine(text, limit: PortholeWire.previewLength)
    }

    /// Whether a finished turn's text asks Jon something: a question mark, or a request for a decision,
    /// in its last paragraph.
    static func asks(_ text: String) -> Bool {
        let paragraphs = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let last = (paragraphs.last(where: { !$0.isEmpty }) ?? "").lowercased()
        // A question in a code block or a link is not a question to Jon.
        let plain = last.replacingOccurrences(of: #"`[^`]*`|\([^)]*\)\]?|https?://\S+"#, with: "", options: .regularExpression)
        if plain.contains("?") { return true }
        let cues = ["shall i", "should i", "do you want", "would you like", "want me to", "let me know", "tell me",
                    "your call", "say \"", "say go", "reply with", "which one", "confirm", "can you ", "could you "]
        return cues.contains { plain.contains($0) }
    }

    // MARK: Text

    static let interrupted = "[Request interrupted by user]"

    /// Your prompt as it reads, or nil for what Claude Code writes in your name (command output, task
    /// notifications, hooks, reminders). A slash command reads as you typed it: "/compact keep the plan".
    static func prompt(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix(interrupted) { return interrupted }
        if text.contains("<command-name>") {
            let name = between(text, "<command-name>", "</command-name>") ?? ""
            let args = between(text, "<command-args>", "</command-args>") ?? ""
            let shown = (name + (args.isEmpty ? "" : " " + args)).trimmingCharacters(in: .whitespaces)
            return shown.isEmpty ? nil : shown
        }
        let machine = ["<local-command", "<task-notification>", "<system-reminder>", "<bash-input>", "<bash-stdout>",
                       "<bash-stderr>", "<user-prompt-submit-hook>", "<command-message>", "Caveat: The messages below"]
        if machine.contains(where: { text.hasPrefix($0) }) { return nil }
        // Text you pasted reads as you pasted it: Claude Code's markers around it go.
        let unwrapped = text.replacingOccurrences(of: #"</?pasted_content[^>]*>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return unwrapped.isEmpty ? nil : unwrapped
    }

    /// One line for a tool use: what it did, not how.
    static func toolLine(_ name: String, _ input: [String: Any]) -> String {
        func s(_ key: String) -> String? {
            guard let v = input[key] as? String, !v.isEmpty else { return nil }
            return v
        }
        let line: String
        switch name {
        case "Bash": line = "Ran: " + (s("description") ?? s("command") ?? "a command")
        case "Read": line = "Read " + path(s("file_path") ?? "a file")
        case "Edit", "MultiEdit": line = "Edited " + path(s("file_path") ?? "a file")
        case "Write": line = "Wrote " + path(s("file_path") ?? "a file")
        case "NotebookEdit": line = "Edited " + path(s("notebook_path") ?? "a notebook")
        case "Grep": line = "Searched for " + (s("pattern") ?? "text")
        case "Glob": line = "Looked for " + (s("pattern") ?? "files")
        case "WebFetch": line = "Fetched " + (s("url") ?? "a page")
        case "WebSearch": line = "Searched the web: " + (s("query") ?? "")
        case "Agent", "Task": line = "Agent: " + (s("description") ?? "a subtask")
        case "Skill": line = "Skill: " + (s("skill") ?? "")
        case "TodoWrite", "TaskCreate", "TaskUpdate": line = "Updated the task list"
        case "AskUserQuestion": line = "Asked you a question"
        default:
            if name.hasPrefix("mcp__") {
                // mcp__<server>__<tool>: "claude-in-chrome: navigate", which says where as well as what.
                let parts = name.components(separatedBy: "__").dropFirst()
                let server = parts.first ?? "mcp", tool = parts.dropFirst().joined(separator: " ")
                line = tool.isEmpty ? "Used \(server)" : "\(server): \(tool.replacingOccurrences(of: "_", with: " "))"
            } else {
                line = "Used " + name
            }
        }
        return oneLine(line, limit: 140)
    }

    /// An `AskUserQuestion`'s first question and its options' labels (at most nine).
    static func question(_ input: [String: Any]) -> (text: String, options: [String])? {
        guard let questions = input["questions"] as? [[String: Any]], let first = questions.first,
              let text = first["question"] as? String else { return nil }
        let options = (first["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }.prefix(9)
        let more = questions.count > 1 ? " (+\(questions.count - 1) more in the terminal)" : ""
        return (text + more, Array(options))
    }

    static func oneLine(_ text: String, limit: Int) -> String {
        var line = text.replacingOccurrences(of: #"[\*_`#>]+"#, with: "", options: .regularExpression)
        line = line.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        line = line.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    static func path(_ p: String) -> String {
        let home = NSHomeDirectory()
        return p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
    }

    static func between(_ text: String, _ open: String, _ close: String) -> String? {
        guard let a = text.range(of: open), let b = text.range(of: close, range: a.upperBound..<text.endIndex) else { return nil }
        return text[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func date(_ s: String) -> Double? {
        (iso.date(from: s) ?? isoPlain.date(from: s))?.timeIntervalSince1970
    }
}

/// A transcript file followed from where the last read stopped. Not thread-safe: one queue owns it.
final class PortholeTranscriptFile {
    let url: URL
    private(set) var model: PortholeTranscript
    private var offset: UInt64 = 0
    private var partial = Data()
    /// The file offset of `partial`'s first byte.
    private var partialStart: UInt64 = 0
    private var inode: UInt64?
    private let keep: Int
    /// Nil: read from the start, so sequence numbers count from the file's first entry. A number: the
    /// first read (and one after a reset) starts this many bytes from the end and skips the partial
    /// first line, for a session followed only for its state and preview.
    private let tailBytes: UInt64?

    init(url: URL, keep: Int = 400, tailBytes: UInt64? = nil) {
        self.url = url
        self.keep = keep
        self.tailBytes = tailBytes
        self.model = PortholeTranscript(keep: keep)
    }

    /// Reads what was added since the last call. `reset` is true when the file was replaced or got
    /// shorter, so everything was read again from the start.
    func readNew() -> (added: [TranscriptEntry], reset: Bool) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return ([], false) }
        let node = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        var reset = false
        if size < offset || (inode != nil && node != inode) {
            model = PortholeTranscript(keep: keep)
            offset = 0; partial = Data(); partialStart = 0; reset = true
        }
        inode = node
        var skipFirstLine = false
        if offset == 0, let tail = tailBytes, size > tail {
            offset = size - tail
            skipFirstLine = true
        }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return ([], reset) }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        var data = handle.readDataToEndOfFile()
        offset += UInt64(data.count)
        var dataStart = offset - UInt64(data.count)
        if skipFirstLine {
            guard let nl = data.firstIndex(of: 0x0A) else { partial = Data(); partialStart = offset; return ([], reset) }
            dataStart += UInt64(nl - data.startIndex + 1)
            data = Data(data[(nl + 1)...])
            partial = Data()
            partialStart = dataStart
        }
        var added: [TranscriptEntry] = []
        let bufferStart = partial.isEmpty ? dataStart : partialStart
        let buffer = partial + data
        var lineStart = buffer.startIndex
        while let nl = buffer[lineStart...].firstIndex(of: 0x0A) {
            added += model.ingest(Data(buffer[lineStart..<nl]), offset: bufferStart + UInt64(lineStart - buffer.startIndex))
            lineStart = nl + 1
        }
        partial = Data(buffer[lineStart...])
        partialStart = bufferStart + UInt64(lineStart - buffer.startIndex)
        return (added, reset)
    }

    /// The end of a file only: enough for a session nobody watches (its title may be older, so it is
    /// looked for in the first part too). `bytes` from the end; the first, partial line is skipped.
    static func probe(url: URL, bytes: UInt64 = 262_144) -> PortholeTranscript {
        var model = PortholeTranscript(keep: 8)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return model }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > bytes ? size - bytes : 0
        try? handle.seek(toOffset: start)
        var data = handle.readDataToEndOfFile()
        if start > 0, let nl = data.firstIndex(of: 0x0A) { data = Data(data[(nl + 1)...]) }
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) { model.ingest(Data(line)) }
        return model
    }
}

/// A terminal's text as iTerm's AppleScript gives it, made into screen rows (pure, checked).
enum PortholeScreenText {
    /// "rows,columns\n<the session's text>" → the screen's last `rows` rows (pure, checked). iTerm gives
    /// logical lines, so one longer than `columns` is wrapped into rows as the terminal shows it.
    static func parse(_ text: String) -> (columns: Int, rows: Int, lines: [String])? {
        guard let nl = text.firstIndex(of: "\n") else { return nil }
        let size = text[..<nl].split(separator: ",").compactMap { Int($0) }
        guard size.count == 2, size[0] > 0, size[1] > 0 else { return nil }
        let rows = size[0], columns = size[1]
        var lines = text[text.index(after: nl)...].components(separatedBy: "\n")
        while lines.last == "" && lines.count > rows { lines.removeLast() }   // the text ends with a newline
        // Only the tail can reach the screen: wrap enough logical lines from the end to fill it.
        var screen: [String] = []
        for line in lines.reversed() {
            var wrapped: [String] = []
            var rest = Substring(line)
            repeat {
                wrapped.append(String(rest.prefix(columns)))
                rest = rest.dropFirst(columns)
            } while !rest.isEmpty
            screen.insert(contentsOf: wrapped, at: 0)
            if screen.count >= rows { break }
        }
        screen = Array(screen.suffix(rows))
        if screen.count < rows { screen += Array(repeating: "", count: rows - screen.count) }
        return (columns, rows, screen)
    }
}
