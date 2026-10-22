import Foundation

// Porthole's AppleScript helper (docs/porthole-plan.md, Terminal). The host never runs AppleScript itself:
// AppleScript must run on a main thread, and a slow iTerm2 kept the host's main thread waiting for its
// answer (an Apple Event waits up to two minutes by default), freezing the stream with it (found 17 Oct).
// This process runs it on its own main thread instead: one JSON request per line on standard input,
// {"id": 1, "handler": "screenof", "args": ["4052", "<session id>"]}, one answer per line on standard
// output, {"id": 1, "ok": true, "result": "..."}. Every iTerm2 command has a 3 s timeout, and the host
// restarts this helper if an answer is late. Arguments are passed to the handlers as values, never
// spliced into the script.

setvbuf(stdout, nil, _IOLBF, 0)

// Porthole (22 Oct review): two scripts, each compiled the first time it is needed. One script for both apps
// could not compile on a Mac without Chrome or without iTerm2 (each app's own terms need the app), which
// broke both; the host asks for Chrome's tabs only while Chrome runs, and for iTerm2 only for its sessions.
let itermSource = """
on findsession(wid, uid)
    with timeout of 3 seconds
        tell application "iTerm2"
            if wid is not "0" then
                try
                    set s to current session of (first window whose id is (wid as integer))
                    if unique id of s is uid then return s
                end try
            end if
            repeat with w in windows
                repeat with tb in tabs of w
                    repeat with x in sessions of tb
                        if unique id of x is uid then return x
                    end repeat
                end repeat
            end repeat
        end tell
    end timeout
    return missing value
end findsession

on screenof(wid, uid)
    set s to findsession(wid, uid)
    if s is missing value then return ""
    with timeout of 3 seconds
        tell application "iTerm2"
            tell s
                set r to rows
                set c to columns
                set body to contents
            end tell
        end tell
    end timeout
    return (r as text) & "," & (c as text) & (character id 10) & body
end screenof

on resizeto(wid, uid, c, r)
    set s to findsession(wid, uid)
    if s is missing value then return ""
    with timeout of 3 seconds
        tell application "iTerm2"
            tell s
                set oc to columns
                set orw to rows
                set columns to (c as integer)
                set rows to (r as integer)
            end tell
        end tell
    end timeout
    return (oc as text) & "," & (orw as text)
end resizeto

on typeinto(wid, uid, body)
    set s to findsession(wid, uid)
    if s is missing value then return "missing"
    with timeout of 3 seconds
        tell application "iTerm2" to tell s to write text body newline no
    end timeout
    return "ok"
end typeinto
"""

let chromeSource = """
on chrometabs()
    set sep to character id 9
    set eol to character id 10
    set out to ""
    with timeout of 4 seconds
        tell application "Google Chrome"
            repeat with w in windows
                set b to bounds of w
                set out to out & "W" & sep & (id of w) & sep & (active tab index of w) & sep & (item 1 of b) & sep & (item 2 of b) & sep & (item 3 of b) & sep & (item 4 of b) & eol
                set ids to id of tabs of w
                set titles to title of tabs of w
                set urls to URL of tabs of w
                repeat with i from 1 to count of ids
                    set out to out & "T" & sep & (item i of ids) & sep & i & sep & (item i of titles) & sep & (item i of urls) & eol
                end repeat
            end repeat
        end tell
    end timeout
    return out
end chrometabs

on activatetab(wid, tid)
    with timeout of 3 seconds
        tell application "Google Chrome"
            set w to (first window whose id is (wid as integer))
            set ids to id of tabs of w
            repeat with i from 1 to count of ids
                if ((item i of ids) as text) is tid then
                    set active tab index of w to i
                    set index of w to 1
                    return "ok"
                end if
            end repeat
        end tell
    end timeout
    return "missing"
end activatetab
"""

struct Request: Decodable { let id: Int; let handler: String; let args: [String] }
struct Answer: Encodable { let id: Int; let ok: Bool; let result: String? }

/// Each script compiled on first use; nil after it failed to (its app isn't installed), and tried again a minute later.
var scripts: [String: NSAppleScript] = [:]
var failedAt: [String: Date] = [:]

func script(for handler: String) -> NSAppleScript? {
    let key = ["chrometabs", "activatetab"].contains(handler) ? "chrome" : "iterm"
    if let s = scripts[key] { return s }
    if let at = failedAt[key], Date().timeIntervalSince(at) < 60 { return nil }
    var compileError: NSDictionary?
    guard let s = NSAppleScript(source: key == "chrome" ? chromeSource : itermSource), s.compileAndReturnError(&compileError) else {
        FileHandle.standardError.write("PortholeOSAHelper: the \(key) script did not compile: \(compileError ?? [:])\n".data(using: .utf8)!)
        failedAt[key] = Date()
        return nil
    }
    scripts[key] = s
    return s
}

func code(_ s: String) -> FourCharCode { s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) } }

/// Calls `handler` with `args`, as a handler call (kASAppleScriptSuite 'ascr', kASSubroutineEvent 'psbr',
/// keyASSubroutineName 'snam').
func call(_ handler: String, _ args: [String]) -> (Bool, String?) {
    let event = NSAppleEventDescriptor(eventClass: code("ascr"), eventID: code("psbr"), targetDescriptor: .currentProcess(),
                                       returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    event.setDescriptor(NSAppleEventDescriptor(string: handler.lowercased()), forKeyword: code("snam"))
    let list = NSAppleEventDescriptor.list()
    for (i, arg) in args.enumerated() { list.insert(NSAppleEventDescriptor(string: arg), at: i + 1) }
    event.setParam(list, forKeyword: keyDirectObject)
    guard let script = script(for: handler) else { return (false, nil) }
    var error: NSDictionary?
    let result = script.executeAppleEvent(event, error: &error)
    return error == nil ? (true, result.stringValue) : (false, nil)
}

let encoder = JSONEncoder()
while let line = readLine(strippingNewline: true) {
    guard let request = try? JSONDecoder().decode(Request.self, from: Data(line.utf8)),
          ["screenof", "resizeto", "typeinto", "chrometabs", "activatetab"].contains(request.handler) else { continue }
    let (ok, result) = call(request.handler, request.args)
    if let data = try? encoder.encode(Answer(id: request.id, ok: ok, result: result)), let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}
