import Foundation
import StreamProtocol

/// Porthole (docs/agent-view-plan.md, phase 2): an iTerm session's screen with its colours, for the session
/// mirror. AppleScript gives text only, which is why the 17 Oct view's colours were wrong; iTerm's Python
/// API gives every cell's own colour and style. A helper on that API (iTerm's `iterm2` library, in
/// Porthole's private environment under ~/Library/Application Support/Porthole/venv, never the system
/// Python) answers one request per line: `{"id", "session"}` in, the screen as styled runs out. iTerm lets
/// it in with a cookie it hands out over AppleScript, which Porthole may already use. Without the
/// environment, `screen` is nil and the mirror stays text, as before. Safe from any queue (one call at a time).
/// Porthole (22 Oct): it also reads the session's history (two-finger scroll), finds words in it, and types.
final class PortholeITermScreen: @unchecked Sendable {
    struct Screen {
        var columns: Int
        var rows: Int
        var cursorX: Int
        var cursorY: Int
        var lines: [[TerminalRun]]
        /// Porthole: the session's line number of the first line here, of the live screen's first line, and
        /// the lines of history above the live screen (iTerm's numbering, which counts lines it dropped).
        var first = 0
        var base = 0
        var history = 0
        var scrolledUp: Int { max(0, base - first) }
    }

    static let folder = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Porthole")
    static var python: URL { folder.appendingPathComponent("venv/bin/python") }
    static var script: URL { folder.appendingPathComponent("iterm-screen.py") }

    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var nextID = 1
    private let lines = LineBuffer()
    private var failedAt: Date?
    /// The colour set in use: "dark", "light", or nil (the Mac's appearance), as the watching device asked.
    var colours: String? { didSet { if colours != oldValue { palette = PortholeTermPalette.iTerm(colours) } } }
    private(set) var palette = PortholeTermPalette.iTerm()

    private final class LineBuffer: @unchecked Sendable {
        let lock = NSLock()
        let ready = DispatchSemaphore(value: 0)
        var pending = Data()
        var lines: [Data] = []
        func append(_ data: Data) {
            lock.lock()
            pending.append(data)
            var count = 0
            while let nl = pending.firstIndex(of: 0x0A) {
                lines.append(Data(pending[pending.startIndex..<nl]))
                pending = Data(pending[(nl + 1)...])
                count += 1
            }
            lock.unlock()
            for _ in 0..<count { ready.signal() }
        }
        func next() -> Data? {
            lock.lock(); defer { lock.unlock() }
            return lines.isEmpty ? nil : lines.removeFirst()
        }
    }

    /// The session's screen, or nil (no helper, iTerm said no, too slow): the caller reads text instead.
    /// Porthole: from line `first` of its history (iTerm's line number), or `scrolledUp` lines above the live
    /// screen; the live screen without either, or once they reach it.
    func screen(_ terminalID: String, first: Int? = nil, scrolledUp: Int? = nil, timeout: TimeInterval = 2) -> Screen? {
        var request: [String: Any] = ["session": terminalID]
        if let scrolledUp, scrolledUp > 0 { request["scroll"] = scrolledUp } else if let first { request["first"] = first }
        return call(request, timeout: timeout).flatMap(parse)
    }

    /// Porthole: every place the words are in the session's history and screen, ignoring case (line number,
    /// column), oldest first, and the live screen's first line number.
    func find(_ terminalID: String, _ query: String) -> (matches: [(line: Int, column: Int)], base: Int)? {
        guard let a = call(["session": terminalID, "find": query], timeout: 4), a["ok"] as? Bool == true,
              let raw = a["matches"] as? [[Int]] else { return nil }
        return (raw.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }, a["base"] as? Int ?? 0)
    }

    /// Porthole: types into the session through iTerm's API (a few ms; AppleScript's write took ~50).
    /// False when the helper isn't there or iTerm said no: the caller types through AppleScript.
    func type(_ text: String, into terminalID: String) -> Bool {
        call(["session": terminalID, "type": text], timeout: 1)?["ok"] as? Bool == true
    }

    private func call(_ request: [String: Any], timeout: TimeInterval) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        let started = process?.isRunning != true
        guard ensureRunning(), let input else { return nil }
        // A helper just started still has to load iTerm's library and connect (2–4 s measured): its first
        // answer gets longer.
        let timeout = started ? max(timeout, 10) : timeout
        let id = nextID
        nextID += 1
        var request = request
        request["id"] = id
        guard let body = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        do { try input.write(contentsOf: body + Data([0x0A])) } catch { stop(); return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 || lines.ready.wait(timeout: .now() + left) == .timedOut {
                print("Porthole: the iTerm screen helper did not answer within \(Int(timeout)) s; restarting it")
                stop()
                return nil
            }
            guard let line = lines.next(), let answer = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  answer["id"] as? Int == id else { continue }
            return answer
        }
    }

    private func parse(_ a: [String: Any]) -> Screen? {
        guard a["ok"] as? Bool == true, let columns = a["cols"] as? Int, let rows = a["rows"] as? Int,
              let raw = a["lines"] as? [[[Any]]] else { return nil }
        func rgb(_ v: Any?) -> UInt32? {
            switch v {
            case let i as Int: return palette.indexed(i)
            case let s as String where s == "fg": return palette.foreground
            case let s as String where s == "bg": return palette.background
            case let s as String: return UInt32(s, radix: 16)
            default: return nil
            }
        }
        let lines = raw.map { runs in
            runs.compactMap { r -> TerminalRun? in
                guard r.count == 4, let text = r[0] as? String else { return nil }
                let style = UInt8((r[3] as? Int) ?? 0)
                return TerminalRun(text: text, fg: rgb(r[1]), bg: rgb(r[2]), style: style == 0 ? nil : style)
            }
        }
        return Screen(columns: columns, rows: rows, cursorX: a["cx"] as? Int ?? -1, cursorY: a["cy"] as? Int ?? -1, lines: lines,
                      first: a["first"] as? Int ?? 0, base: a["base"] as? Int ?? 0, history: a["history"] as? Int ?? 0)
    }

    private func ensureRunning() -> Bool {
        if let process, process.isRunning { return true }
        // A helper that would not start is tried again a minute later, not on every refresh.
        if let failedAt, Date().timeIntervalSince(failedAt) < 60 { return false }
        guard FileManager.default.isExecutableFile(atPath: Self.python.path) else { return false }
        do {
            try Self.source.write(to: Self.script, atomically: true, encoding: .utf8)
        } catch { failedAt = Date(); return false }
        let p = Process()
        p.executableURL = Self.python
        p.arguments = ["-I", Self.script.path]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        let buffer = lines
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { buffer.append(data) }
        }
        do { try p.run() } catch { print("Porthole: could not start the iTerm screen helper: \(error)"); failedAt = Date(); return false }
        process = p
        input = stdin.fileHandleForWriting
        print("Porthole: iTerm screen helper started (colours for the session mirror)")
        return true
    }

    private func stop() {
        process?.terminate()
        process = nil
        input = nil
        failedAt = Date()
    }

    deinit { process?.terminate() }

    /// The helper, written beside its environment when it starts. Colours go out as an index (0–255, the
    /// host's palette), "RRGGBB", "fg" or "bg" (the default the other way round), or null (the default).
    static let source = #"""
import asyncio, json, sys
import iterm2
import iterm2.screen

def colour(c, reversed_default):
    if c is None:
        return None
    if c.is_rgb:
        return "%02X%02X%02X" % (c.rgb.red, c.rgb.green, c.rgb.blue)
    if c.is_standard:
        return c.standard
    if c.is_alternate and c.alternate == iterm2.screen.CellStyle.AlternateColor.REVERSED_DEFAULT:
        return reversed_default
    return None

def styled(line, cols):
    runs, key, text = [], None, ""
    for x in range(cols):
        st = line.style_at(x)
        try:
            ch = line.string_at(x)
        except Exception:
            ch = " "
        if ch == "" and x > 0 and st is not None:
            continue  # the second cell of a wide character
        if ch == "":
            ch = " "
        if st is None:
            k = (None, None, 0)
        else:
            f = (1 if st.bold else 0) | (2 if st.italic else 0) | (4 if st.underline else 0) \
                | (8 if st.inverse else 0) | (16 if st.faint else 0) | (32 if st.strikethrough else 0)
            k = (colour(st.fg_color, "bg"), colour(st.bg_color, "fg"), f)
        if k == key:
            text += ch
        else:
            if key is not None and text:
                runs.append([text, key[0], key[1], key[2]])
            key, text = k, ch
    if key is not None and text:
        if key == (None, None, 0):
            text = text.rstrip(" ")
        if text:
            runs.append([text, key[0], key[1], key[2]])
    return runs

async def screen(connection, app, req):
    s = app.get_session_by_id(req["session"])
    if s is None:
        return {"ok": False, "why": "no such session"}
    cols, rows = s.grid_size.width, s.grid_size.height
    async with iterm2.Transaction(connection):
        li = await s.async_get_line_info()
        base = li.overflow + li.scrollback_buffer_height
        first = None
        if req.get("scroll"):
            first = base - int(req["scroll"])
        elif req.get("first") is not None:
            first = int(req["first"])
        if first is not None:
            first = max(li.overflow, min(first, base))
        if first is None or first >= base:
            sc = await s.async_get_screen_contents()
            lines = [sc.line(i) for i in range(min(sc.number_of_lines, rows))]
            c = sc.cursor_coord
            cx, cy, first = c.x, c.y - sc.number_of_lines_above_screen, base
        else:
            lines = await s.async_get_contents(first, rows)
            cx, cy = -1, -1
    out = [styled(line, cols) for line in lines]
    return {"ok": True, "cols": cols, "rows": rows, "cx": cx, "cy": cy, "lines": out,
            "first": first, "base": base, "history": li.scrollback_buffer_height}

async def find(connection, app, req):
    """Every line of the session's history and screen that has the words, ignoring case: [line, column]."""
    s = app.get_session_by_id(req["session"])
    if s is None:
        return {"ok": False, "why": "no such session"}
    q = req["find"].casefold()
    async with iterm2.Transaction(connection):
        li = await s.async_get_line_info()
        total = li.scrollback_buffer_height + li.mutable_area_height
        lines = await s.async_get_contents(li.overflow, total)
    hits = []
    for i, line in enumerate(lines):
        text = line.string.casefold()
        at = text.find(q)
        while at >= 0 and len(hits) < 2000:
            hits.append([li.overflow + i, at])
            at = text.find(q, at + max(1, len(q)))
    return {"ok": True, "matches": hits, "base": li.overflow + li.scrollback_buffer_height}

async def type_text(app, req):
    s = app.get_session_by_id(req["session"])
    if s is None:
        return {"ok": False, "why": "no such session"}
    await s.async_send_text(req["type"], suppress_broadcast=True)
    return {"ok": True}

async def main(connection):
    app = await iterm2.async_get_app(connection)
    loop = asyncio.get_running_loop()
    while True:
        line = await loop.run_in_executor(None, sys.stdin.readline)
        if not line:
            return
        try:
            req = json.loads(line)
        except Exception:
            continue
        try:
            if "type" in req:
                out = await type_text(app, req)
            elif "find" in req:
                out = await find(connection, app, req)
            else:
                out = await screen(connection, app, req)
        except Exception as e:
            out = {"ok": False, "why": str(e)}
        out["id"] = req.get("id")
        sys.stdout.write(json.dumps(out) + "\n")
        sys.stdout.flush()

iterm2.run_until_complete(main)
"""#
}
