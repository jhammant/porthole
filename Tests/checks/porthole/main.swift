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

print("\(passes) checks, \(fails) failed")
exit(Int32(fails))
