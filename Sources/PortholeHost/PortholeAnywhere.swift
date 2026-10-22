import Foundation
import Network
import StreamProtocol

/// Porthole Anywhere on the Mac (21 Oct 2026): when a Claude Code session comes to need you, each registered
/// device that isn't connected right now gets a push notification through anywhere.hammantlabs.com
/// (Server/anywhere), which checks the device's Anywhere subscription and hands it to Apple's push service.
/// Devices register over the paired connection (kind 212); the registrations are kept in
/// ~/Library/Application Support/Porthole/anywhere.json, so a phone in a pocket still hears. A watcher of its
/// own reads the sessions every 6 s, only while a device is registered: the feed for connected devices
/// (PortholeHost) stops when they leave. What leaves the Mac: the session's title and its last line, the
/// device's token and its signed subscription, to that server only, which keeps none of it.
final class PortholeAnywhereHost: @unchecked Sendable {
    struct Registration: Codable, Equatable {
        var token: String
        var env: String
        var jws: String
        var name: String
        var updated: Double
        /// Porthole (22 Oct review): the subscription period this JWS proves is over; nothing goes to the device
        /// until it registers again with its renewed one (it does on its next connection to this Mac).
        var lapsed: Bool? = nil
    }

    static let endpoint = URL(string: ProcessInfo.processInfo.environment["PORTHOLE_ANYWHERE_URL"] ?? "https://anywhere.hammantlabs.com/v1/notify")!
    static let file = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PORTHOLE_ANYWHERE_FILE"]
        ?? NSHomeDirectory() + "/Library/Application Support/Porthole/anywhere.json")

    private let queue = DispatchQueue(label: "porthole.anywhere", qos: .utility)
    private var registrations: [String: Registration] = [:]
    private var connected: [ObjectIdentifier: String] = [:]
    private let sessions = PortholeSessions()
    private var lastStates: [String: ClaudeSession.State]?
    /// The sessions that need you, each with when its question began, as last looked.
    private var announced: [String: Double] = [:]
    private var timer: DispatchSourceTimer?

    init() {
        queue.async {
            if let data = try? Data(contentsOf: Self.file),
               let saved = try? JSONDecoder().decode([String: Registration].self, from: data) { self.registrations = saved }
            self.startIfNeeded()
        }
    }

    func register(_ r: PushRegistration, from connection: NWConnection) {
        queue.async {
            guard !r.token.isEmpty, !r.jws.isEmpty else { return }
            self.connected[ObjectIdentifier(connection)] = r.token
            self.registrations[r.token] = Registration(token: r.token, env: r.env, jws: r.jws, name: r.name,
                                                       updated: Date().timeIntervalSince1970)
            self.save()
            self.startIfNeeded()
            print("Porthole Anywhere: \(r.name) registered for notifications (\(self.registrations.count) device(s))")
        }
    }

    func clientLeft(_ connection: NWConnection) {
        queue.async { self.connected[ObjectIdentifier(connection)] = nil }
    }

    /// Who would be told now, for the Mac's Settings.
    var deviceNames: [String] { queue.sync { registrations.values.map(\.name).sorted() } }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(registrations) {
            try? data.write(to: Self.file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
        }
    }

    private func startIfNeeded() {
        guard timer == nil, !registrations.isEmpty else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 6, leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        guard !registrations.isEmpty else { timer?.cancel(); timer = nil; lastStates = nil; return }
        var list = sessions.snapshot()
        // TEST ONLY: PORTHOLE_TEST_ANYWHERE_FAKE=1 adds a session that comes to need you on the second look,
        // so the checks see a notification without waiting for a real one.
        if ProcessInfo.processInfo.environment["PORTHOLE_TEST_ANYWHERE_FAKE"] == "1", lastStates != nil {
            list.sessions.append(ClaudeSession(id: "test-session", title: "Test session", portal: "test", folder: "test",
                                               state: .needsYou, preview: "Should the limit apply per user or per key?"))
        }
        let now = Dictionary(list.sessions.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
        // The first look only learns the states: nothing that already needed you is announced again. After it,
        // one push per question (22 Oct, the states review): keyed on when it began, so a Working blip from a
        // background task's turn doesn't announce the same question twice.
        let asking = list.sessions.filter { $0.state == .needsYou }
        if lastStates != nil {
            for s in asking where announced[s.id] != (s.since ?? 0) { notify(s) }
        }
        announced = Dictionary(asking.map { ($0.id, $0.since ?? 0) }, uniquingKeysWith: { a, _ in a })
        lastStates = now
    }

    private func notify(_ s: ClaudeSession) {
        let here = Set(connected.values)
        for r in registrations.values where !here.contains(r.token) && r.lapsed != true {
            let body: [String: Any] = ["device": r.token, "env": r.env, "jws": r.jws, "session": s.id,
                                       "title": "\(s.title) needs you", "body": s.preview ?? "Claude is waiting for you."]
            var request = URLRequest(url: Self.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = 15
            let token = r.token, name = r.name
            URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let reason = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["reason"] as? String
                print("Porthole Anywhere: a session needs you → \(SafeText.label(name)): \(code)" + (reason.map { " (\($0))" } ?? ""))
                guard code == 402 else { return }
                self?.queue.async {
                    // Not a subscription at all, or refunded: forgotten. A period that ended (the renewal's JWS is
                    // on the device, which sends it on its next connection) only pauses it (22 Oct review: a 402
                    // deleted the registration at every monthly renewal).
                    if reason == "invalid" || reason == "revoked" { self?.registrations[token] = nil }
                    else { self?.registrations[token]?.lapsed = true }
                    self?.save()
                }
            }.resume()
        }
    }
}
