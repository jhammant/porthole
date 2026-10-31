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
        case error(String)          // an API error Claude Code wrote in Claude's place (rate limit, overload, login)
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
    /// Porthole (22 Oct, the states review): Claude Code wrote `system/turn_duration` after Claude's last word,
    /// and nothing has started a turn since. `claude agents` calls a session whose turn is over but whose
    /// background shell still runs "busy"; this says it waits for you.
    private(set) var turnOver = false
    /// Background agents and workflows still running when the turn ended: those do wake Claude, so Working.
    private(set) var background = 0
    /// When Claude asked something you haven't answered. A turn a task notification started doesn't answer it.
    private(set) var openAskAt: Double?
    /// When the current turn began, for the Working list's order (stable while it runs).
    private(set) var turnStartAt: Double?
    /// Porthole (30 Oct, "support codex as well as claude code"): an OpenAI Codex session log
    /// (~/.codex/sessions/…/rollout-*.jsonl) read by the same model. Its records (`session_meta`, `event_msg`,
    /// `response_item`) share no type with Claude Code's. Codex has no `claude agents`: its task running and a
    /// question or approval it waits on come from the log itself (`codexStatus`).
    private(set) var codexBusy = false
    private(set) var codexWaiting = false
    private(set) var codexFirstPrompt: String?
    /// `claude agents`' word for a Codex session: waiting, busy or idle.
    var codexStatus: String { codexWaiting ? "waiting" : codexBusy ? "busy" : "idle" }
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
        case "system":
            if record["subtype"] as? String == "turn_duration" {
                turnOver = true
                background = (record["pendingBackgroundAgentCount"] as? Int ?? 0) + (record["pendingWorkflowCount"] as? Int ?? 0)
                switch tail {
                case .claude(let text) where Self.asks(text): openAskAt = openAskAt ?? tailAt
                case .error: openAskAt = openAskAt ?? tailAt
                default: break
                }
            }
            return []
        case "attachment":
            // A prompt you typed while Claude worked joins the running turn: you have answered.
            if let a = record["attachment"] as? [String: Any], a["type"] as? String == "queued_command",
               a["humanTurn"] as? Bool == true { openAskAt = nil }
            return []
        case "user":
            if record["isMeta"] as? Bool == true || record["isCompactSummary"] as? Bool == true
                || record["isSidechain"] as? Bool == true { return [] }
            guard let message = record["message"] as? [String: Any] else { return [] }
            // Any text, yours or a task notification's, starts a turn.
            if message["content"] is String
                || (message["content"] as? [[String: Any]])?.contains(where: { $0["type"] as? String == "text" }) == true {
                if turnOver || turnStartAt == nil { turnStartAt = at }
                turnOver = false
            }
            if let text = message["content"] as? String { return you(text, at: at) }
            var added: [TranscriptEntry] = []
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "tool_result":
                    // Answering a pending AskUserQuestion answers the question.
                    if let id = block["tool_use_id"] as? String, pending[id] == "AskUserQuestion" { openAskAt = nil }
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
            turnOver = false
            let apiError = record["isApiErrorMessage"] as? Bool == true
            var added: [TranscriptEntry] = []
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    lastClaudeText = text
                    tail = apiError ? .error(text) : .claude(text); tailAt = at
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
        case "event_msg":
            return codexEvent(record["payload"] as? [String: Any] ?? [:], at: at)
        case "response_item":
            return codexItem(record["payload"] as? [String: Any] ?? [:], at: at)
        default:
            return []
        }
    }

    // MARK: Codex

    private mutating func codexEvent(_ p: [String: Any], at: Double?) -> [TranscriptEntry] {
        let type = p["type"] as? String ?? ""
        switch type {
        case "task_started":
            codexBusy = true; turnOver = false
            turnStartAt = at
            return []
        case "task_complete":
            codexBusy = false; codexWaiting = false; turnOver = true
            if case .claude(let text) = tail, Self.asks(text) { openAskAt = openAskAt ?? tailAt }
            return []
        case "turn_aborted":
            codexBusy = false; codexWaiting = false; turnOver = true
            openAskAt = nil
            tail = .you; tailAt = at
            return [add(.tool, "Interrupted by you", at: at)]
        case "user_message":
            return codexPrompt(Self.codexText(p["message"]), at: at)
        case "agent_message":
            return codexSays(Self.codexText(p["message"]), at: at)
        case "item_completed":
            // Items happen only inside a task: one after the last task_complete means a task runs, even when
            // its task_started is further back than the window read (a long task writes megabytes).
            codexBusy = true
            let item = p["item"] as? [String: Any] ?? [:]
            switch item["type"] as? String {
            case "UserMessage": return codexPrompt(Self.codexText(item["content"]), at: at)
            case "AgentMessage": return codexSays(Self.codexText(item["content"]), at: at)
            case "CommandExecution": return codexTool("Shell", Self.codexCommand(item), at: at)
            case "McpToolCall": return codexTool(item["server"] as? String ?? "MCP", item["tool"] as? String ?? "", at: at)
            case "FileChange": return codexTool("Edit", Self.codexFiles(item), at: at)
            case "Extension": return codexTool("Search", item["query"] as? String ?? "", at: at)
            default: return []
            }
        case "error":
            let text = Self.codexText(p["message"])
            tail = .error(text.isEmpty ? "Codex hit an error" : text); tailAt = at
            return []
        default:
            // A command or a patch waiting for your yes, or Codex asking you something.
            guard type.hasSuffix("approval_request") || type == "request_user_input" || type == "elicitation_request" else { return [] }
            codexWaiting = true
            openAskAt = openAskAt ?? at
            tail = .toolPending("Approval"); tailAt = at
            return [add(.tool, "Waiting for your approval", at: at)]
        }
    }

    /// The model's own items: only its questions to you (request_user_input) are of use here; its words and
    /// tools come as `item_completed` events.
    private mutating func codexItem(_ p: [String: Any], at: Double?) -> [TranscriptEntry] {
        guard p["type"] as? String == "function_call", (p["name"] as? String ?? "").hasPrefix("request_user_input"),
              let raw = (p["arguments"] as? String)?.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let q = (args["questions"] as? [[String: Any]])?.first else { return [] }
        let text = (q["title"] as? String) ?? (q["question"] as? String) ?? "Codex has a question"
        let options = (q["options"] as? [Any])?.compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["label"] as? String) }
        codexWaiting = true
        openAskAt = openAskAt ?? at
        tail = .toolPending("Question"); tailAt = at
        return [add(.question, text, options: options?.isEmpty == false ? options : nil, at: at)]
    }

    private mutating func codexPrompt(_ raw: String, at: Double?) -> [TranscriptEntry] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Codex's own context, written as your message by older versions.
        guard !text.isEmpty, !text.hasPrefix("<environment_context>"), !text.hasPrefix("<user_instructions>") else { return [] }
        if codexFirstPrompt == nil { codexFirstPrompt = text }
        codexWaiting = false
        if turnOver || turnStartAt == nil { turnStartAt = at }
        turnOver = false
        openAskAt = nil
        tail = .you; tailAt = at
        return [add(.you, text, at: at)]
    }

    private mutating func codexSays(_ raw: String, at: Double?) -> [TranscriptEntry] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        lastClaudeText = text
        tail = .claude(text); tailAt = at
        return [add(.claude, text, at: at)]
    }

    private mutating func codexTool(_ name: String, _ detail: String, at: Double?) -> [TranscriptEntry] {
        // A tool ran: the approval it waited on was given.
        if codexWaiting { openAskAt = nil }
        codexWaiting = false
        tail = .toolDone; tailAt = at
        let line = detail.isEmpty ? name : "\(name): \(detail)"
        return [add(.tool, String(line.prefix(160)), at: at)]
    }

    /// A Codex message's words: a string, or content blocks with `text`.
    static func codexText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        return (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    static func codexCommand(_ item: [String: Any]) -> String {
        if let parsed = item["parsed_cmd"] as? [[String: Any]], let cmd = parsed.first?["cmd"] as? String { return cmd }
        if let parts = item["command"] as? [String] { return parts.last ?? "" }
        return item["command"] as? String ?? ""
    }

    static func codexFiles(_ item: [String: Any]) -> String {
        let names = ((item["changes"] as? [String: Any])?.keys.map { ($0 as NSString).lastPathComponent } ?? []).sorted()
        return names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " and \(names.count - 3) more" : "")
    }

    private mutating func you(_ raw: String, at: Double?) -> [TranscriptEntry] {
        guard let text = Self.prompt(raw) else { return [] }
        // Your prompt, or your Esc, answers whatever was open.
        openAskAt = nil
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
    func state(busy: Bool) -> ClaudeSession.State { state(status: busy ? "busy" : "idle") }

    /// The session's state for the sidebar, given `claude agents`' word for it: busy, idle or waiting.
    func state(status: String) -> ClaudeSession.State {
        if status == "waiting" { return .needsYou }   // a permission prompt or a question in the terminal
        // Busy with the turn over means only a background shell runs (the CLI reports "shell" as busy): Claude
        // waits for you. Background agents and workflows still count as working.
        if status == "busy", !(turnOver && background == 0) { return .working }
        if openAskAt != nil { return .needsYou }
        switch tail {
        case .toolPending, .error: return .needsYou
        case .claude(let text): return Self.asks(text) ? .needsYou : .done
        case .you, .nothing, .toolDone: return .idle
        }
    }

    /// When the state began: an open question's time, the turn's start while working, else the tail's.
    func since(for state: ClaudeSession.State) -> Double? {
        switch state {
        case .needsYou: return openAskAt ?? tailAt
        case .working: return turnStartAt ?? tailAt
        default: return tailAt
        }
    }

    /// Claude's last text as one line for the sidebar.
    var preview: String? {
        guard let text = lastClaudeText else { return nil }
        return Self.oneLine(text, limit: PortholeWire.previewLength)
    }

    /// Whether a finished turn's text asks Jon something, judged on its last sentence as Claude Code's agent
    /// view judges it (22 Oct, the states review: any "?" or cue word in the last paragraph flagged 29% of
    /// finished turns, "confirmed" and "if you'd rather…, tell me" among them). A question then a one-line
    /// sign-off still asks; an offer Claude can take or leave ("Want me to also add tests?") doesn't.
    static func asks(_ text: String) -> Bool {
        // Code, link targets and URLs are not questions to you; emphasis goes so "**Shall I?**" ends in "?".
        let plain = text
            .replacingOccurrences(of: #"(?s)```.*?```"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"`[^`]*`|\]\([^)]*\)|https?://\S+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[*_]+"#, with: "", options: .regularExpression)
        let paragraphs = plain.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let last = paragraphs.last else { return false }
        var sentences = [lastSentence(last)]
        // "Shall I send it?" then a one-line sign-off: the question is still the ask.
        if paragraphs.count > 1, !last.contains("\n"), last.count <= 160 { sentences.append(lastSentence(paragraphs[paragraphs.count - 2])) }
        return sentences.contains(where: isAsk)
    }

    /// A paragraph's last line, then that line's last sentence.
    static func lastSentence(_ p: String) -> String {
        let line = p.components(separatedBy: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? p
        let parts = line.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"([.!?])\s+(?=\S)"#, with: "$1\u{1F}", options: .regularExpression)
            .components(separatedBy: "\u{1F}")
        return (parts.last ?? line).trimmingCharacters(in: .whitespaces)
    }

    static func isAsk(_ sentence: String) -> Bool {
        let s = sentence.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "()").union(.whitespaces))
        func has(_ p: String) -> Bool { s.range(of: p, options: .regularExpression) != nil }
        // An offer Claude can take or leave ("Want me to also add tests?") is done; Claude Code judges it so too.
        if has(#"\b(want|like) me to\b|\b(shall|should) i also\b"#) { return false }
        // A question in quotes is a quotation (a draft's words), not one to you.
        let quoted = has(#"["“][^"”]*[?？]["”][)\]]*$"#)
        if !quoted, has(#"[?？]["')\]]*$"#) { return true }
        // A conditional offer ("if you'd rather keep it, tell me") asks nothing either.
        if has(#"^(if|when|once|whenever|otherwise)\b|\bif you\b"#) { return false }
        return has(#"\b(shall i|should i (proceed|continue|go ahead|send)|do you want|which (one|option|approach)|your call|say "?(go|yes|send)\b|reply with|please (confirm|choose|decide|pick|approve|run|provide)|can you confirm|let me know (which|what|whether|if|how|when)|tell me (which|what|whether|if))\b"#)
    }

    // MARK: Text

    static let interrupted = "[Request interrupted by user]"

    /// Your prompt as it reads, or nil for what Claude Code writes in your name (command output, task
    /// notifications, hooks, reminders). A slash command reads as you typed it: "/compact keep the plan".
    static func prompt(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // "[Request interrupted by user]" and "… for tool use]" both.
        if text.hasPrefix("[Request interrupted by user") { return interrupted }
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
    private var tailBytes: UInt64?

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
        // Porthole (22 Oct, the states review): only bookkeeping in the window (a compaction after the last turn
        // writes ~300 KB of attachments): look further back, up to 4 MB.
        if skipFirstLine, model.tail == .nothing, let w = tailBytes, size > w, w < 4 << 20 {
            tailBytes = w * 4
            model = PortholeTranscript(keep: keep); offset = 0; partial = Data(); partialStart = 0
            return readNew()
        }
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
