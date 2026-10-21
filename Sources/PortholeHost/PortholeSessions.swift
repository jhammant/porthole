import AppKit
import Foundation
import StreamProtocol

/// Porthole (docs/porthole-plan.md, Mac side): the Claude Code sessions running on this Mac, for the
/// device's sidebar. `claude agents --json` names them (pid, session id, folder, busy or idle); `ps`
/// gives each process's terminal; iTerm2, through AppleScript, says which window and session show that
/// terminal. iTerm's AppleScript window id is the window server's CGWindowID (checked 16 Oct 2026), the
/// same number Porthole's window list uses. Each session's state comes from the end of its transcript.
///
/// Not thread-safe: one serial queue owns it (PortholeHost). Each `snapshot` costs two short processes
/// (`claude agents`, `ps`), one AppleScript call and a read of each changed transcript's last 256 KB.
final class PortholeSessions {
    struct Agent: Decodable {
        let pid: Int32
        let sessionId: String
        let cwd: String
        let name: String
        let status: String
        let kind: String
    }

    struct ITermSession {
        let windowID: UInt32
        let tty: String          // "/dev/ttys015"
        let uniqueID: String
        let title: String
    }

    private let home = NSHomeDirectory()
    /// Each live session's transcript, followed from its last 256 KB on: only what was added since the
    /// last look is read (a working session writes all the time).
    private var followers: [String: PortholeTranscriptFile] = [:]
    /// A process's terminal never changes, so `ps` runs only for processes not seen before.
    private var ttyCache: [Int32: String] = [:]
    /// iTerm's sessions, asked again when a session's terminal is not among them, or after 10 s (for
    /// titles and windows opened or closed).
    private var iterm: [ITermSession] = []
    private var itermAt: Date = .distantPast
    private var files: [String: URL] = [:]
    /// Where `claude` lives, found once.
    private lazy var claude: String? = Self.findClaude()
    /// The last snapshot's sessions by id, for replies and the terminal view.
    private(set) var byID: [String: ClaudeSession] = [:]

    // MARK: Snapshot

    func snapshot() -> SessionList {
        let agents = Self.agents(claude: claude)
        let unknown = agents.map(\.pid).filter { ttyCache[$0] == nil }
        if !unknown.isEmpty { ttyCache.merge(Self.ttys(of: unknown)) { _, new in new } }
        let live = Set(agents.map(\.pid))
        ttyCache = ttyCache.filter { live.contains($0.key) }
        let ttys = ttyCache
        var byTTY = Dictionary(iterm.map { ($0.tty, $0) }, uniquingKeysWith: { a, _ in a })
        let missing = agents.contains { a in ttys[a.pid].map { byTTY[$0] == nil } ?? false }
        if missing || Date().timeIntervalSince(itermAt) > 10 {
            iterm = Self.itermSessions()
            itermAt = Date()
            byTTY = Dictionary(iterm.map { ($0.tty, $0) }, uniquingKeysWith: { a, _ in a })
        }
        var sessions: [ClaudeSession] = []
        for agent in agents {
            let terminal = ttys[agent.pid].flatMap { byTTY[$0] }
            let model = probe(sessionID: agent.sessionId)
            let place = Self.portal(for: agent.cwd, home: home)
            let state = model?.state(busy: agent.status == "busy") ?? (agent.status == "busy" ? .working : .idle)
            let title = model?.title ?? terminal.map { Self.cleanTitle($0.title) }.flatMap { $0.isEmpty ? nil : $0 } ?? agent.name
            sessions.append(ClaudeSession(id: agent.sessionId, title: title, portal: place.portal, folder: place.folder,
                                          state: state, since: model?.tailAt, windowID: terminal?.windowID,
                                          windowNumber: nil, terminalID: terminal?.uniqueID, preview: model?.preview))
        }
        let list = SessionList(sessions: Self.ordered(sessions), windowOrder: Self.frontToBack())
        byID = Dictionary(list.sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Forget the followers of sessions that ended, so a long run does not keep every transcript.
        let ids = Set(agents.map(\.sessionId))
        followers = followers.filter { ids.contains($0.key) }
        return list
    }

    /// The transcript file of a session, found once (a project folder per working folder).
    func file(for sessionID: String) -> URL? {
        if let url = files[sessionID] { return url }
        let root = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects")
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        for folder in folders {
            let candidate = folder.appendingPathComponent(sessionID + ".jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) {
                files[sessionID] = candidate
                return candidate
            }
        }
        return nil
    }

    private func probe(sessionID: String) -> PortholeTranscript? {
        guard let url = file(for: sessionID) else { return nil }
        let follower = followers[sessionID] ?? PortholeTranscriptFile(url: url, keep: 8, tailBytes: 262_144)
        followers[sessionID] = follower
        _ = follower.readNew()
        return follower.model
    }

    /// The Mac's normal windows front to back (the window server lists on-screen windows in that order).
    static func frontToBack() -> [UInt32] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0, let id = w[kCGWindowNumber as String] as? Int else { return nil }
            return UInt32(id)
        }
    }

    // MARK: Order and names (pure, checked)

    /// The sidebar's order: needs you (longest wait first), done (newest first), working, idle; ties by
    /// title.
    static func ordered(_ sessions: [ClaudeSession]) -> [ClaudeSession] {
        func rank(_ s: ClaudeSession.State) -> Int {
            switch s { case .needsYou: return 0; case .done: return 1; case .working: return 2; case .idle: return 3 }
        }
        return sessions.sorted { a, b in
            if rank(a.state) != rank(b.state) { return rank(a.state) < rank(b.state) }
            let ta = a.since ?? 0, tb = b.since ?? 0
            if ta != tb {
                return a.state == .needsYou ? ta < tb : ta > tb
            }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    /// One rule for naming a session's group: a folder under the home folder ("dev/acme"), and its label.
    struct GroupRule: Codable, Equatable { let folder: String; let label: String }

    /// The rules in ~/Library/Application Support/Porthole/groups.json, `[{"folder": "dev/acme", "label":
    /// "Acme"}, …]`, read once; none when there is no file.
    static let groupRules: [GroupRule] = {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Porthole/groups.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([GroupRule].self, from: data)) ?? []
    }()

    /// The group a working folder belongs to, and the folder under the home folder. The first rule whose
    /// folder it is, or is under, names it (any case); without one, the folder's own name under ~/dev (or
    /// under the home folder): "dev/acme/api" is "acme", the home folder itself "Home".
    static func portal(for cwd: String, home: String, rules: [GroupRule] = groupRules) -> (portal: String, folder: String) {
        var folder = cwd
        if folder == home { folder = "" } else if folder.hasPrefix(home + "/") { folder = String(folder.dropFirst(home.count + 1)) }
        let lower = folder.lowercased()
        func under(_ prefix: String) -> Bool { let p = prefix.lowercased(); return lower == p || lower.hasPrefix(p + "/") }
        if let rule = rules.first(where: { under($0.folder) }) { return (rule.label, folder.isEmpty ? "~" : folder) }
        let parts = folder.split(separator: "/").map(String.init)
        let portal: String
        if parts.isEmpty { portal = "Home" }
        else if parts[0] == "dev", parts.count > 1 { portal = parts[1] }
        else { portal = parts[0] }
        return (portal, folder.isEmpty ? "~" : folder)
    }

    /// An iTerm session's name without Claude Code's status mark and iTerm's " (node)" suffix:
    /// "◐ GitLab dev repo monitoring (node)" → "GitLab dev repo monitoring".
    static func cleanTitle(_ name: String) -> String {
        var t = name.trimmingCharacters(in: .whitespaces)
        if let first = t.unicodeScalars.first, !CharacterSet.alphanumerics.contains(first), !"-~/.".unicodeScalars.contains(first) {
            t = String(t.unicodeScalars.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if let r = t.range(of: #"\s\([^()]*\)$"#, options: .regularExpression) { t.removeSubrange(r) }
        return t
    }

    // MARK: The processes

    static func findClaude() -> String? {
        let candidates = [ProcessInfo.processInfo.environment["PORTHOLE_CLAUDE"],
                          NSHomeDirectory() + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func agents(claude: String?) -> [Agent] {
        guard let claude, let out = run(claude, ["agents", "--json"], timeout: 5) else { return [] }
        return (try? JSONDecoder().decode([Agent].self, from: out)) ?? []
    }

    /// Each pid's controlling terminal as a device path ("/dev/ttys015"); none for `claude --bg`.
    static func ttys(of pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty,
              let out = run("/bin/ps", ["-o", "pid=,tty=", "-p", pids.map(String.init).joined(separator: ",")], timeout: 3),
              let text = String(data: out, encoding: .utf8) else { return [:] }
        var map: [Int32: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let pid = Int32(parts[0]), parts[1] != "??" else { continue }
            map[pid] = "/dev/" + parts[1]
        }
        return map
    }

    /// iTerm2's sessions, only while iTerm2 runs (asking a stopped iTerm2 would launch it).
    static func itermSessions() -> [ITermSession] {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.googlecode.iterm2").isEmpty == false else { return [] }
        // Four bulk requests, not one per property per session (80 round trips took 2.8 s on 16 Oct).
        // The separators are set outside the tell block: inside it, `tab` is iTerm's tab object.
        let script = """
        set sep to character id 9
        set eol to character id 10
        tell application "iTerm2"
            set wids to id of windows
            set ttys to tty of every session of every tab of every window
            set uids to unique id of every session of every tab of every window
            set names to name of every session of every tab of every window
        end tell
        set out to ""
        repeat with i from 1 to count of wids
            set wid to item i of wids
            repeat with j from 1 to count of (item i of ttys)
                repeat with k from 1 to count of (item j of item i of ttys)
                    set out to out & wid & sep & (item k of item j of item i of ttys) & sep & (item k of item j of item i of uids) & sep & (item k of item j of item i of names) & eol
                end repeat
            end repeat
        end repeat
        return out
        """
        guard let out = run("/usr/bin/osascript", ["-e", script], timeout: 5), let text = String(data: out, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4, let wid = UInt32(f[0]) else { return nil }
            return ITermSession(windowID: wid, tty: f[1], uniqueID: f[2], title: f[3])
        }
    }

    /// Runs a tool and returns its standard output, or nil if it fails or overruns `timeout` seconds.
    static func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> Data? {
        final class Box: @unchecked Sendable { var data = Data() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return nil }
        // Read on another thread while it runs, so a large output never fills the pipe and stalls it.
        let box = Box()
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.data = out.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = read.wait(timeout: .now() + 1)
            return nil
        }
        _ = read.wait(timeout: .now() + 2)
        return p.terminationStatus == 0 ? box.data : nil
    }
}
