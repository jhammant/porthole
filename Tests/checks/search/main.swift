// The search across sessions (PortholeSearch), on two made-up transcripts. Every check prints ok or FAIL;
// the exit status is the number of failures.
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
var fails = 0
func check(_ name: String, _ ok: Bool) {
    if ok { print("ok   \(name)") } else { fails += 1; print("FAIL \(name)") }
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
func record(_ r: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: r), encoding: .utf8)! }
func you(_ text: String, _ at: String) -> String { record(["type": "user", "timestamp": at, "message": ["role": "user", "content": text]]) }
func claude(_ blocks: [[String: Any]], _ at: String, sidechain: Bool = false) -> String {
    record(["type": "assistant", "timestamp": at, "isSidechain": sidechain, "message": ["role": "assistant", "content": blocks]])
}
func result(_ text: String, _ at: String) -> String {
    record(["type": "user", "timestamp": at, "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": text]]]])
}

let a = dir.appendingPathComponent("a.jsonl"), b = dir.appendingPathComponent("b.jsonl")
try! [
    you("Add rate limiting to the public API", "2026-10-20T10:00:00Z"),
    claude([["type": "thinking", "thinking": "the Token bucket is simplest"]], "2026-10-20T10:00:01Z"),
    claude([["type": "text", "text": "I'll add a token-bucket limiter as middleware."]], "2026-10-20T10:00:02Z"),
    claude([["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "npm test", "description": "Run the token tests"]]], "2026-10-20T10:00:03Z"),
    result("PASS token bucket 6 tests", "2026-10-20T10:00:04Z"),
    claude([["type": "text", "text": "A subagent's TOKEN words"]], "2026-10-20T10:00:05Z", sidechain: true),
    claude([["type": "text", "text": "Done: the TOKEN bucket allows 100 requests a minute per client, and each client gets its own bucket so one noisy script can't starve the rest."]], "2026-10-20T10:00:06Z"),
].joined(separator: "\n").write(to: a, atomically: true, encoding: .utf8)
try! [
    you("Why does the token refresh fail?", "2026-10-21T09:00:00Z"),
    claude([["type": "text", "text": "The refresh token expired."]], "2026-10-21T09:00:01Z"),
].joined(separator: "\n").write(to: b, atomically: true, encoding: .utf8)

let sources = [PortholeSearch.Source(sessionID: "a", url: a), PortholeSearch.Source(sessionID: "b", url: b)]
let found = PortholeSearch.search("token", in: sources)
check("both sessions match", Set(found.map(\.sessionID)) == ["a", "b"])
check("the session with the newest match comes first", found.first?.sessionID == "b")
let inA = found.first { $0.sessionID == "a" }
check("Claude's words and its tool line count; thinking, tool results and side chains don't",
      inA?.count == 3)
check("newest first in a session", inA?.hits.first?.snippet.contains("100 requests") == true)
check("roles come through", inA?.hits.map(\.role) == [.claude, .tool, .claude])
check("a long text's snippet is cut with an ellipsis", inA?.hits.first.map { $0.snippet.hasSuffix("…") } == true)
check("a prompt matches", PortholeSearch.search("refresh fail", in: sources).first?.hits.first?.role == .you)
check("nothing found is nothing", PortholeSearch.search("zq9xv nothing", in: sources).isEmpty)
check("one letter searches nothing", PortholeSearch.search("t", in: sources).isEmpty)
check("a missing file is skipped", PortholeSearch.search("token", in: sources + [PortholeSearch.Source(sessionID: "c", url: dir.appendingPathComponent("gone.jsonl"))]).count == 2)

let text = Data("one\ntwo three\nfour".utf8)
check("a line's bounds, first", PortholeSearch.lineBounds(text, around: 1) == 0..<3)
check("a line's bounds, middle", PortholeSearch.lineBounds(text, around: 6) == 4..<13)
check("a line's bounds, last", PortholeSearch.lineBounds(text, around: 16) == 14..<18)
check("a snippet keeps the match", PortholeSearch.snippet("alpha beta GAMMA delta", "gamma") == "alpha beta GAMMA delta")

print(fails == 0 ? "search: all passed" : "search: \(fails) failed")
exit(Int32(fails))
