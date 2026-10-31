import Foundation
import StreamProtocol

/// Porthole (30 Oct, "can we get it to support codex as well as claude code"): OpenAI Codex sessions in a
/// terminal, beside Claude Code's. Codex has no `claude agents`: `ps` finds the `codex` processes running a
/// session in a terminal, and `lsof` the session log each holds open (~/.codex/sessions/…/rollout-*.jsonl),
/// which PortholeTranscript reads as it reads Claude Code's. `codex exec`, the app server and the like are
/// not sessions and are left out.
enum PortholeCodex {
    struct Found: Equatable {
        /// "/dev/ttys015", as iTerm names it.
        let tty: String
        /// The session's log; nil until its first turn (Codex opens it then).
        let log: URL?
        let cwd: String?

        /// "codex-<the log's uuid>", or the terminal's before there is a log.
        var id: String {
            if let log, let uuid = PortholeCodex.uuid(in: log.lastPathComponent) { return "codex-" + uuid }
            return "codex-" + (tty as NSString).lastPathComponent
        }
    }

    /// Codex's subcommands that aren't a session in a terminal.
    static let notSessions: Set<String> = ["exec", "e", "app-server", "exec-server", "mcp", "mcp-server", "login", "logout",
                                           "completion", "apply", "a", "cloud", "sandbox", "debug", "proto", "responses-api-proxy",
                                           "help", "features", "generate-ts"]
    /// Codex's options that take a value, so the value isn't read as a subcommand.
    static let valueFlags: Set<String> = ["-c", "--config", "-m", "--model", "-p", "--profile", "-s", "--sandbox", "-a",
                                          "--ask-for-approval", "-C", "--cd", "-i", "--image", "--add-dir", "--enable", "--disable",
                                          "--remote", "--oss-provider", "--local-provider"]

    /// From one line of `ps -axo pid=,tty=,args=`: a Codex process in a terminal that runs a session.
    static func process(_ line: Substring) -> (pid: Int32, tty: String)? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3, let pid = Int32(parts[0]), parts[1] != "??" else { return nil }
        var args = Array(parts[2...])
        // The npm package runs as `node …/bin/codex …`; its native child as `…/vendor/…/bin/codex …`.
        if (args[0] as NSString).lastPathComponent == "node" { args.removeFirst() }
        guard let exe = args.first, (exe as NSString).lastPathComponent == "codex", isSession(args) else { return nil }
        return (pid, "/dev/" + parts[1])
    }

    /// `codex`, `codex "a prompt"`, `codex resume …`: a session; `codex exec …` and the servers: not.
    static func isSession(_ args: [String]) -> Bool {
        var i = 1
        while i < args.count {
            let a = args[i]
            if valueFlags.contains(a) { i += 2; continue }
            if a.hasPrefix("-") { i += 1; continue }
            return !notSessions.contains(a)
        }
        return true
    }

    /// `lsof -Fpfn`'s answer: each process's working folder and the Codex log it holds open.
    static func openFiles(_ text: String) -> (cwd: [Int32: String], log: [Int32: String]) {
        var cwd: [Int32: String] = [:], log: [Int32: String] = [:]
        var pid: Int32?, fd = ""
        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value); fd = ""
            case "f": fd = value
            case "n":
                guard let pid else { continue }
                if fd == "cwd" { cwd[pid] = value }
                else if value.contains("/.codex/sessions/"), (value as NSString).lastPathComponent.hasPrefix("rollout-"),
                        value.hasSuffix(".jsonl") { log[pid] = value }
            default: break
            }
        }
        return (cwd, log)
    }

    /// The uuid at the end of "rollout-2026-10-30T22-53-47-01a18f04-ed4a-7e42-a7cd-191a041d5bcb.jsonl".
    static func uuid(in name: String) -> String? {
        guard let r = name.range(of: #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?=\.jsonl$)"#,
                                 options: .regularExpression) else { return nil }
        return String(name[r])
    }

    /// Every Codex session in a terminal now, one per terminal. One `ps`, and `lsof` only when there is one.
    static func sessions() -> [Found] {
        guard let out = PortholeSessions.run("/bin/ps", ["-axo", "pid=,tty=,args="], timeout: 3),
              let text = String(data: out, encoding: .utf8) else { return [] }
        let procs = text.split(separator: "\n").compactMap(process)
        guard !procs.isEmpty else { return [] }
        // lsof says 1 when one of the processes has gone meanwhile; its answer for the rest still stands.
        let files = PortholeSessions.run("/usr/sbin/lsof", ["-a", "-p", procs.map { String($0.pid) }.joined(separator: ","), "-Fpfn"],
                                         timeout: 3, allowFailure: true)
            .flatMap { String(data: $0, encoding: .utf8) }.map(openFiles) ?? (cwd: [:], log: [:])
        var byTTY: [String: Found] = [:]
        // Newest process first, so of two sessions in one folder the newer takes the newer log.
        for p in procs.sorted(by: { $0.pid > $1.pid }) {
            let log = files.log[p.pid].map { URL(fileURLWithPath: $0) }
            let had = byTTY[p.tty]
            // The node wrapper and its native child share the terminal: what either knows counts.
            byTTY[p.tty] = Found(tty: p.tty, log: had?.log ?? log, cwd: had?.cwd ?? files.cwd[p.pid])
        }
        // Codex's terminal app now writes its log through its app server, so the process holds none open: the
        // log is the newest one a terminal session wrote for the same folder (30 Oct, codex-cli 0.166).
        var taken = Set(byTTY.values.compactMap { $0.log?.path })
        let recent = recentLogs()
        for (tty, f) in byTTY.sorted(by: { $0.key < $1.key }) where f.log == nil {
            guard let cwd = f.cwd, let log = recent.first(where: { $0.cwd == cwd && !taken.contains($0.url.path) }) else { continue }
            taken.insert(log.url.path)
            byTTY[tty] = Found(tty: tty, log: log.url, cwd: cwd)
        }
        return byTTY.values.sorted { $0.tty < $1.tty }
    }

    /// What a log's first line says: its folder, and whether a terminal session wrote it (not `codex exec`).
    struct Meta { let cwd: String; let terminal: Bool }
    /// First lines never change: read once per log. Behind a lock: the device's list and Anywhere's take
    /// their snapshots on queues of their own (31 Oct: a test host crashed writing it from both at once).
    nonisolated(unsafe) private static var metas: [String: Meta] = [:]
    private static let metasLock = NSLock()

    /// The last week's logs from terminal sessions, newest first.
    static func recentLogs(now: Date = Date()) -> [(url: URL, cwd: String)] {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
        let days = (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: now) }
        let fm = FileManager.default
        var logs: [(url: URL, cwd: String, at: Date)] = []
        for day in days {
            let c = Calendar.current.dateComponents([.year, .month, .day], from: day)
            guard let y = c.year, let m = c.month, let d = c.day else { continue }
            let folder = root.appendingPathComponent(String(format: "%04d/%02d/%02d", y, m, d))
            for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
                metasLock.lock()
                let known = metas[url.path]
                metasLock.unlock()
                guard let meta = known ?? readMeta(url) else { continue }
                if known == nil { metasLock.lock(); metas[url.path] = meta; metasLock.unlock() }
                guard meta.terminal else { continue }
                let at = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                logs.append((url, meta.cwd, at))
            }
        }
        return logs.sorted { $0.at > $1.at }.map { ($0.url, $0.cwd) }
    }

    /// The log's first line, `session_meta`: its folder, and who wrote it.
    static func readMeta(_ url: URL) -> Meta? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 512 * 1024), let nl = head.firstIndex(of: 0x0A) ?? (head.isEmpty ? nil : head.endIndex),
              let record = try? JSONSerialization.jsonObject(with: head[head.startIndex..<nl]) as? [String: Any],
              record["type"] as? String == "session_meta", let p = record["payload"] as? [String: Any], let cwd = p["cwd"] as? String
        else { return nil }
        return Meta(cwd: cwd, terminal: isTerminal(originator: p["originator"] as? String, source: p["source"]))
    }

    /// `codex exec` writes "codex_exec"/"exec"; a sub-agent's log is its parent's business.
    static func isTerminal(originator: String?, source: Any?) -> Bool {
        if originator == "codex_exec" || (source as? String) == "exec" { return false }
        if let s = source as? [String: Any], s["subagent"] != nil { return false }
        return true
    }

    /// The sidebar's name for it: the terminal's title unless that only says Codex, else the first thing
    /// you asked (its first line, cut), else "Codex".
    static func title(terminal: String?, firstPrompt: String?) -> String {
        if let t = terminal.map(PortholeSessions.cleanTitle), !t.isEmpty,
           !["codex", "node", "zsh", "bash", "-zsh"].contains(t.lowercased()) { return t }
        if let line = firstPrompt?.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces), !line.isEmpty {
            return line.count > 60 ? String(line.prefix(59)) + "…" : line
        }
        return "Codex"
    }
}
