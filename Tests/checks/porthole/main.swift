// Porthole's pure checks (docs/porthole-plan.md, Judges). Every check prints ok or FAIL; the exit status
// is the number of failures.
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
var fails = 0, passes = 0
func check(_ name: String, _ ok: Bool) {
    if ok { passes += 1; print("ok   \(name)") } else { fails += 1; print("FAIL \(name)") }
}
func json(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }
let ts = "2026-10-16T22:00:00.000Z"
func user(_ text: String, extra: [String: Any] = [:]) -> Data {
    json(["type": "user", "timestamp": ts, "message": ["role": "user", "content": text]].merging(extra) { $1 })
}
func assistantText(_ text: String) -> Data {
    json(["type": "assistant", "timestamp": ts, "message": ["role": "assistant", "content": [["type": "text", "text": text]]]])
}
func toolUse(_ id: String, _ name: String, _ input: [String: Any]) -> Data {
    json(["type": "assistant", "timestamp": ts, "message": ["role": "assistant", "content": [["type": "tool_use", "id": id, "name": name, "input": input]]]])
}
func toolResult(_ id: String) -> Data {
    json(["type": "user", "timestamp": ts, "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": "done"]]]])
}

// MARK: Transcript entries
var t = PortholeTranscript()
t.ingest(json(["type": "ai-title", "aiTitle": "GitLab dev repo monitoring"]))
check("title from ai-title", t.title == "GitLab dev repo monitoring")
t.ingest(json(["type": "custom-title", "customTitle": "Acme · memory architecture"]))
check("a given name beats the ai-title", t.title == "Acme · memory architecture")
t.ingest(json(["type": "ai-title", "aiTitle": "Diarize call notes and deck update"]))
check("a later ai-title keeps the given name", t.title == "Acme · memory architecture")
t.ingest(json(["type": "custom-title", "customTitle": "Acme · sidebar blur fix"]))
check("a rename is followed", t.title == "Acme · sidebar blur fix")
var added = t.ingest(user("watch the gitlab repo"))
check("a prompt is your entry", added.count == 1 && added[0].role == .you && added[0].text == "watch the gitlab repo" && added[0].seq == 1)
check("a prompt's time is read", added.first?.at == PortholeTranscript.date(ts))
check("meta and side chains are left out",
      t.ingest(user("hidden", extra: ["isMeta": true])).isEmpty && t.ingest(user("sub", extra: ["isSidechain": true])).isEmpty)
check("machine text is left out", t.ingest(user("<task-notification>x</task-notification>")).isEmpty
      && t.ingest(user("<system-reminder>y</system-reminder>")).isEmpty && t.ingest(user("<local-command-stdout>z")).isEmpty)
added = t.ingest(user("<command-name>/compact</command-name><command-args>keep the plan</command-args>"))
check("a slash command reads as typed", added.first?.text == "/compact keep the plan")
added = t.ingest(user("look:\n<pasted_content id=\"e86c\">Error 403</pasted_content id=\"e86c\">"))
check("pasted text loses its markers", added.first?.text == "look:\nError 403")
added = t.ingest(toolUse("t1", "Bash", ["command": "ls -la", "description": "List the files"]))
check("a tool use is one line", added.first?.role == .tool && added.first?.text == "Ran: List the files")
check("a pending tool use needs you when idle", t.state(busy: false) == .needsYou)
check("busy is working whatever the tail", t.state(busy: true) == .working)
t.ingest(toolResult("t1"))
check("its result clears it: idle after a finished tool with no text", t.state(busy: false) == .idle)
t.ingest(assistantText("All done. The relay is live."))
check("Claude's text that asks nothing is done", t.state(busy: false) == .done)
check("preview is Claude's last text, one line", t.preview == "All done. The relay is live.")
t.ingest(assistantText("I've drafted it.\n\nShall I send it?"))
check("a question in the last paragraph needs you", t.state(busy: false) == .needsYou)
t.ingest(assistantText("See `git status?` and https://example.com/a?b=1 for more."))
check("a question mark in code or a link does not ask", t.state(busy: false) == .done)
added = t.ingest(toolUse("q1", "AskUserQuestion", ["questions": [["question": "Which layout?", "options": [["label": "Two"], ["label": "Four"]]]]]))
check("a question entry carries its options", added.first?.role == .question && added.first?.options == ["Two", "Four"] && added.first?.text == "Which layout?")
check("a pending question needs you", t.state(busy: false) == .needsYou)
added = t.ingest(user("[Request interrupted by user]"))
check("Esc reads as an interruption and ends what was pending", added.first?.text == "Interrupted by you" && t.state(busy: false) == .idle)
added = t.ingest(toolUse("m1", "mcp__claude-in-chrome__tabs_context_mcp", [:]))
check("an MCP tool names its server", added.first?.text == "claude-in-chrome: tabs context mcp")
check("sequence numbers run on", t.entries.map(\.seq) == Array(1...t.seq))
var small = PortholeTranscript(keep: 3)
for i in 0..<5 { small.ingest(user("p\(i)")) }
check("only the newest entries are kept, numbers intact", small.entries.map(\.seq) == [3, 4, 5] && small.seq == 5)
check("bad lines are skipped", PortholeTranscript().state(busy: false) == .idle && { var x = PortholeTranscript(); return x.ingest(Data("not json".utf8)).isEmpty }())

// MARK: The transcript file: offsets, the tail, appends
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("porthole-check-\(getpid()).jsonl")
func line(_ d: Data) -> Data { d + Data([0x0A]) }
var body = Data()
for i in 0..<40 { body += line(user("prompt \(i) " + String(repeating: "x", count: 200))) }
try! body.write(to: tmp)
let tail = PortholeTranscriptFile(url: tmp, tailBytes: 2000)
let first = tail.readNew().added
check("a tail read starts at a whole line", first.first.map { $0.text.hasPrefix("prompt ") } == true && first.count < 40)
check("numbers are offsets × 16, increasing", first.allSatisfy { $0.seq % 16 == 0 } && zip(first, first.dropFirst()).allSatisfy { $0.seq < $1.seq })
let lastBefore = first.last!.seq
let handle = try! FileHandle(forWritingTo: tmp)
handle.seekToEndOfFile()
let next = line(user("appended prompt"))
handle.write(next.prefix(10))      // half a line
var more = tail.readNew().added
check("half a line waits", more.isEmpty)
handle.write(next.dropFirst(10))
more = tail.readNew().added
check("the rest of it lands, numbered after the others", more.count == 1 && more[0].text == "appended prompt" && more[0].seq > lastBefore
      && more[0].seq == Int(body.count) * 16)
try? handle.close()
try? FileManager.default.removeItem(at: tmp)

// MARK: Order, portals, titles
func s(_ id: String, _ st: ClaudeSession.State, _ since: Double?, _ title: String = "x") -> ClaudeSession {
    ClaudeSession(id: id, title: title, portal: "Dev", folder: "dev", state: st, since: since)
}
let ordered = PortholeSessions.ordered([s("w", .working, 50), s("d1", .done, 10), s("n1", .needsYou, 30), s("i", .idle, 99),
                                         s("n2", .needsYou, 20), s("d2", .done, 40)]).map(\.id)
check("order: needs you longest first, done newest first, working, idle", ordered == ["n2", "n1", "d2", "d1", "w", "i"])
let home = "/Users/jon"
let rules = [PortholeSessions.GroupRule(folder: "dev/acme", label: "Acme"), PortholeSessions.GroupRule(folder: "dev/family", label: "Personal"),
             PortholeSessions.GroupRule(folder: "dev/toys", label: "Personal")]
check("group: a rule's folder", PortholeSessions.portal(for: "/Users/jon/dev/acme/api", home: home, rules: rules) == ("Acme", "dev/acme/api"))
check("group: a rule, any case", PortholeSessions.portal(for: "/Users/jon/dev/ACME", home: home, rules: rules).portal == "Acme")
check("group: two folders, one label", PortholeSessions.portal(for: "/Users/jon/dev/toys/kite", home: home, rules: rules).portal == "Personal")
check("group: a prefix of a name is not a match", PortholeSessions.portal(for: "/Users/jon/dev/acmeish", home: home, rules: rules).portal == "acmeish")
check("group: no rule, the folder under ~/dev", PortholeSessions.portal(for: "/Users/jon/dev/widgets/app", home: home, rules: []).portal == "widgets")
check("group: no rule, outside ~/dev", PortholeSessions.portal(for: "/Users/jon/notes/x", home: home, rules: []).portal == "notes")
check("group: the home folder", PortholeSessions.portal(for: "/Users/jon", home: home, rules: []) == ("Home", "~"))
check("title: status mark and (node) go", PortholeSessions.cleanTitle("◐ GitLab dev repo monitoring (node)") == "GitLab dev repo monitoring")
check("title: ✳ goes", PortholeSessions.cleanTitle("✳ Demo preparation") == "Demo preparation")
check("title: a plain name stays", PortholeSessions.cleanTitle("-zsh") == "-zsh")

// MARK: Replies
check("reply: CRLF becomes LF, ends trimmed", PortholeWire.sanitizedReply("  a\r\nb\rc  ") == "a\nb\nc")
check("reply: escape and other controls go, tab stays", PortholeWire.sanitizedReply("x\u{1B}[31my\u{7}\tz\u{9B}") == "x[31my\tz")
check("reply: bidi overrides go", PortholeWire.sanitizedReply("a\u{202E}b\u{2066}c") == "abc")
check("reply: nothing left is nil", PortholeWire.sanitizedReply(" \u{1B}\n ") == nil)
check("reply: cut at the limit", PortholeWire.sanitizedReply(String(repeating: "a", count: 9000))?.count == PortholeWire.maxReplyCharacters)

// MARK: Tiles
let size = CGSize(width: 1366, height: 1000)
let two = PortholeWire.tileFrames(count: 2, in: size, gap: 2)
check("two tiles side by side, inset", two.count == 2 && two[0] == CGRect(x: 1, y: 1, width: 681, height: 998)
      && two[1] == CGRect(x: 684, y: 1, width: 681, height: 998))
let four = PortholeWire.tileFrames(count: 4, in: size, gap: 0)
check("four tiles cover the display exactly", four.count == 4 && four.reduce(0) { $0 + $1.width * $1.height } == size.width * size.height)
check("three windows keep the four-tile grid", PortholeWire.tileFrames(count: 3, in: size).count == 4)
check("one window fills it", PortholeWire.tileFrames(count: 1, in: size) == [CGRect(origin: .zero, size: size)])
check("no windows, no tiles", PortholeWire.tileFrames(count: 0, in: size).isEmpty)

// MARK: Terminal screen
let screen = PortholeScreenText.parse("3,10\nold\none\n0123456789abcde\n")
check("screen: the last rows, a long line wrapped", screen?.lines == ["one", "0123456789", "abcde"] && screen?.columns == 10 && screen?.rows == 3)
check("screen: a short text is padded to its rows", PortholeScreenText.parse("4,20\nhello\n")?.lines == ["hello", "", "", ""])
check("screen: a bad header is refused", PortholeScreenText.parse("x,y\nhello") == nil && PortholeScreenText.parse("no newline") == nil)

// MARK: States, 22 Oct (the states review)
func at(_ t: String) -> String { "2026-10-22T\(t).000Z" }
func turnOver(workflows: Int = 0) -> Data { json(["type": "system", "subtype": "turn_duration", "timestamp": ts, "pendingWorkflowCount": workflows]) }
func said(_ text: String, _ when: String = ts, apiError: Bool = false) -> Data {
    json(["type": "assistant", "timestamp": when, "isApiErrorMessage": apiError, "message": ["role": "assistant", "content": [["type": "text", "text": text]]]])
}
func notification(_ when: String = ts) -> Data { json(["type": "user", "timestamp": when, "message": ["role": "user", "content": "<task-notification>build done</task-notification>"]]) }
func queued() -> Data { json(["type": "attachment", "timestamp": ts, "attachment": ["type": "queued_command", "humanTurn": true, "prompt": "go"]]) }
func states(_ lines: [Data]) -> PortholeTranscript { var m = PortholeTranscript(); for l in lines { m.ingest(l) }; return m }

check("a background shell only (busy, turn over): Done", states([user("fix it"), said("Done."), turnOver()]).state(status: "busy") == .done)
check("…and a question then is Needs you", states([user("fix it"), said("Shall I ship it?"), turnOver()]).state(status: "busy") == .needsYou)
check("background workflows pending: Working", states([user("fix it"), said("Started."), turnOver(workflows: 2)]).state(status: "busy") == .working)
check("a new turn after the last: Working", states([user("a"), said("Done."), turnOver(), user("b")]).state(status: "busy") == .working)
check("a turn a task notification started: Working", states([user("a"), said("Done."), turnOver(), notification()]).state(status: "busy") == .working)
let buried = states([user("a"), said("Shall I send it?", at("10:00:00")), turnOver(), notification(at("10:05:00")), said("The build finished.", at("10:06:00")), turnOver()])
check("a question a task notification's turn buried still needs you", buried.state(status: "idle") == .needsYou)
check("…since the question, not the later turn", buried.since(for: .needsYou) == PortholeTranscript.date(at("10:00:00")))
var answered = buried; answered.ingest(user("yes, send it"))
check("your prompt answers it", answered.state(status: "busy") == .working && answered.openAskAt == nil)
var queuedAnswer = buried; queuedAnswer.ingest(queued())
check("a prompt typed mid-turn answers it", queuedAnswer.openAskAt == nil)
var asked = states([user("a"), toolUse("q1", "AskUserQuestion", ["questions": [["question": "Which?", "options": [["label": "A"], ["label": "B"]]]]]), said("Which one?"), turnOver()])
asked.ingest(toolResult("q1"))
check("answering AskUserQuestion answers it", asked.openAskAt == nil)
check("waiting is Needs you whatever the tail", states([user("a"), said("Done."), turnOver()]).state(status: "waiting") == .needsYou)
check("an API error is Needs you", states([user("a"), said("API Error: overloaded", apiError: true), turnOver()]).state(status: "idle") == .needsYou)
var interrupt = states([user("a"), toolUse("t9", "Bash", ["command": "ls"])])
interrupt.ingest(user("[Request interrupted by user for tool use]"))
check("the tool-use interrupt reads as an interrupt", interrupt.entries.last?.text == "Interrupted by you" && interrupt.state(status: "idle") == .idle)
let working = states([user("a", extra: ["timestamp": at("09:00:00")]), toolUse("t1", "Bash", ["command": "x"]), said("Running.", at("09:30:00"))])
check("Working's since is the turn's start, so the order holds still", working.since(for: .working) == PortholeTranscript.date(at("09:00:00")))
for text in ["I confirmed the fix is live.", "Want me to also add tests?", "If you'd rather keep the old name, tell me.",
             "Draft: \"Are you free Tuesday?\"\n\nIt's in the outbox.", "- open: does it need a flag?\n- next: ship",
             "See `git status?` and https://example.com/a?b=1"] {
    check("asks nothing: \(text.prefix(40))", !PortholeTranscript.asks(text))
}
for text in ["Shall I send it?", "Which layout do you want, two or four?", "Ready. Say \"go\" and I'll send it.",
             "Please confirm the date.", "Shall I send it?\n\nEverything else is done.", "(Shall I merge it?)"] {
    check("asks: \(text.prefix(40))", PortholeTranscript.asks(text))
}

// claude agents --json: an entry missing a key drops only itself (22 Oct: one without `status` emptied the list).
let agentsJSON = Data(#"[{"pid":1,"sessionId":"a","cwd":"/x","name":"one","status":"busy","kind":"interactive"},{"pid":2,"sessionId":"b","cwd":"/y","name":"two","kind":"interactive"},{"pid":3,"cwd":"/z"}]"#.utf8)
let decodedAgents = PortholeSessions.decodeAgents(agentsJSON)
check("agents: one entry missing status still reads, one missing its id drops alone", decodedAgents?.map(\.sessionId) == ["a", "b"] && decodedAgents?[1].status == nil)
check("agents: not a list is a failed read, not no sessions", PortholeSessions.decodeAgents(Data("{}".utf8)) == nil)
check("agents: an empty list is no sessions", PortholeSessions.decodeAgents(Data("[]".utf8))?.isEmpty == true)


// MARK: Codex (30 Oct, "support codex as well as claude code")
func codexEvent(_ payload: [String: Any]) -> Data { json(["type": "event_msg", "timestamp": ts, "payload": payload]) }
func codexItem(_ item: [String: Any]) -> Data { codexEvent(["type": "item_completed", "item": item]) }
var cx = PortholeTranscript()
cx.ingest(json(["type": "session_meta", "timestamp": ts, "payload": ["id": "01a18f04", "cwd": "/Users/x/dev/acme"]]))
check("codex: nothing yet is idle", cx.state(status: cx.codexStatus) == .idle)
cx.ingest(codexEvent(["type": "task_started", "turn_id": "t1"]))
cx.ingest(codexItem(["type": "UserMessage", "content": [["type": "text", "text": "Make the site\nwith two pages"]]]))
check("codex: a running task is working", cx.state(status: cx.codexStatus) == .working)
check("codex: your prompt is an entry and the first prompt", cx.entries.last?.role == .you && cx.codexFirstPrompt == "Make the site\nwith two pages")
cx.ingest(codexItem(["type": "CommandExecution", "command": ["/bin/zsh", "-lc", "ls"], "parsed_cmd": [["type": "list_files", "cmd": "ls"]]]))
check("codex: a command is a tool line", cx.entries.last?.role == .tool && cx.entries.last?.text == "Shell: ls")
cx.ingest(codexItem(["type": "FileChange", "changes": ["/a/b/index.html": ["type": "add"], "/a/b/app.js": ["type": "add"]]]))
check("codex: a file change names the files", cx.entries.last?.text == "Edit: app.js, index.html")
cx.ingest(codexEvent(["type": "exec_approval_request", "command": ["rm", "x"]]))
check("codex: an approval request needs you", cx.state(status: cx.codexStatus) == .needsYou)
cx.ingest(codexItem(["type": "CommandExecution", "command": ["rm", "x"]]))
check("codex: the command ran, so it works again", cx.state(status: cx.codexStatus) == .working)
cx.ingest(codexItem(["type": "AgentMessage", "content": [["type": "Text", "text": "Done: two pages."]], "phase": "final"]))
cx.ingest(codexEvent(["type": "task_complete", "last_agent_message": "Done: two pages."]))
check("codex: finished without a question is done", cx.state(status: cx.codexStatus) == .done && cx.preview == "Done: two pages.")
cx.ingest(codexEvent(["type": "task_started"]))
cx.ingest(codexItem(["type": "UserMessage", "content": [["type": "text", "text": "Now deploy it"]]]))
cx.ingest(codexItem(["type": "AgentMessage", "content": [["type": "Text", "text": "Ready to push. Shall I deploy it?"]]]))
cx.ingest(codexEvent(["type": "task_complete"]))
check("codex: finished on a question needs you", cx.state(status: cx.codexStatus) == .needsYou)
check("codex: the first prompt stays the first", cx.codexFirstPrompt == "Make the site\nwith two pages")
cx.ingest(codexEvent(["type": "task_started"]))
cx.ingest(codexEvent(["type": "turn_aborted", "reason": "interrupted"]))
check("codex: Esc stops it, idle", cx.state(status: cx.codexStatus) == .idle && cx.entries.last?.text == "Interrupted by you")
var q = PortholeTranscript()
q.ingest(codexEvent(["type": "task_started"]))
q.ingest(json(["type": "response_item", "timestamp": ts, "payload": ["type": "function_call", "name": "request_user_input_async",
        "arguments": #"{"questions":[{"title":"Group prizes by?","options":["Topic","Decade"]}]}"#]]))
check("codex: a question to you is a question entry and needs you", q.entries.last?.role == .question && q.entries.last?.options == ["Topic", "Decade"]
      && q.state(status: q.codexStatus) == .needsYou)
var long = PortholeTranscript()
long.ingest(codexItem(["type": "AgentMessage", "content": [["type": "Text", "text": "Adding background to every prize."]]]))
long.ingest(codexItem(["type": "CommandExecution", "command": ["node", "build.js"]]))
check("codex: items past the window's start mean a task runs (its start not read)", long.state(status: long.codexStatus) == .working)
var old = PortholeTranscript()
old.ingest(codexEvent(["type": "user_message", "message": "<environment_context>cwd</environment_context>"]))
old.ingest(codexEvent(["type": "user_message", "message": "fix the test"]))
old.ingest(codexEvent(["type": "agent_message", "message": "Fixed."]))
check("codex: older logs' messages read too, context left out", old.entries.map(\.text) == ["fix the test", "Fixed."])
var mixed = PortholeTranscript()
mixed.ingest(user("hello"))
mixed.ingest(codexEvent(["type": "task_started"]))
check("codex: Claude Code's lines keep their own state (no codex flags from them)", PortholeTranscript().codexStatus == "idle" && mixed.entries.count == 1)

check("codex: an interactive session counts", PortholeCodex.process("4242 ttys015 /opt/homebrew/bin/codex") != nil)
check("codex: node wrapper with a prompt counts", PortholeCodex.process("4243 ttys016 node /x/bin/codex -m gpt fix the tests")?.tty == "/dev/ttys016")
check("codex: resume counts", PortholeCodex.process("4244 ttys017 codex resume --last") != nil)
check("codex: exec doesn't", PortholeCodex.process("4245 ttys018 node /x/bin/codex exec --sandbox workspace-write do it") == nil)
check("codex: a value flag isn't a subcommand", PortholeCodex.process("4246 ttys019 codex -c model=x exec go") == nil
      && PortholeCodex.process("4247 ttys019 codex -C /tmp/apply") != nil)
check("codex: the app server (no terminal) doesn't", PortholeCodex.process("4248 ?? /Applications/x/codex app-server --listen stdio://") == nil)
check("codex: other tools named codex-something don't", PortholeCodex.process("4249 ttys020 /x/codex-code-mode-host") == nil)
let lsof = "p100\nfcwd\nn/Users/x/dev/acme\nf3\nn/Users/x/.codex/log/codex-tui.log\nf7\nn/Users/x/.codex/sessions/2026/10/30/rollout-2026-10-30T22-53-47-01a18f04-ed4a-7e42-a7cd-191a041d5bcb.jsonl\np101\nfcwd\nn/tmp\n"
let opened = PortholeCodex.openFiles(lsof)
check("codex: lsof gives the folder and the session log", opened.cwd[100] == "/Users/x/dev/acme" && opened.cwd[101] == "/tmp"
      && opened.log[100]?.hasSuffix("01a18f04-ed4a-7e42-a7cd-191a041d5bcb.jsonl") == true && opened.log[101] == nil)
let found = PortholeCodex.Found(tty: "/dev/ttys015", log: URL(fileURLWithPath: opened.log[100]!), cwd: nil)
check("codex: the id is the log's uuid, else the terminal's", found.id == "codex-01a18f04-ed4a-7e42-a7cd-191a041d5bcb"
      && PortholeCodex.Found(tty: "/dev/ttys015", log: nil, cwd: nil).id == "codex-ttys015")
check("codex: a real terminal title wins", PortholeCodex.title(terminal: "◐ Docs site (codex)", firstPrompt: "x") == "Docs site")
check("codex: a title that only says codex gives way to the first prompt", PortholeCodex.title(terminal: "codex", firstPrompt: "Make the site\nwith two") == "Make the site")
check("codex: nothing at all is Codex", PortholeCodex.title(terminal: nil, firstPrompt: nil) == "Codex")

print("\(passes) checks, \(fails) failed")
exit(Int32(fails))
