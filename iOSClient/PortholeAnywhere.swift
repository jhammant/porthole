import StoreKit
import UIKit
import UserNotifications
import StreamProtocol

/// Porthole Anywhere on the device (21 Oct 2026): a subscription for a notification when a Claude session on
/// the Mac needs you. Subscribed, the device asks to notify, gets its push token, and gives the token and its
/// signed subscription to the Mac it is connected to (kind 212, PushRegistration); the Mac then asks
/// anywhere.hammantlabs.com to notify it (PortholeAnywhereHost). A notification's tap opens its session.
/// "Send a test notification" asks the server straight from the device, so it can be tried without a Mac.
@MainActor
final class PortholeAnywhere: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = PortholeAnywhere()
    static let productIDs = ["io.hammant.porthole.anywhere.monthly", "io.hammant.porthole.anywhere.yearly"]
    static let server = URL(string: "https://anywhere.hammantlabs.com")!

    @Published private(set) var subscribed = false
    @Published private(set) var products: [Product] = []
    @Published private(set) var jws: String?
    @Published private(set) var token: String?
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    /// Opens a session from a tapped notification (PortholeShell sets it).
    var openSession: ((String) -> Void)?
    private var pendingSession: String?
    private var updates: Task<Void, Never>?

    /// Development builds get their pushes from Apple's sandbox, TestFlight and the App Store from production.
    var env: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    func start() {
        UNUserNotificationCenter.current().delegate = self
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await self?.refresh()
            }
        }
        Task { await refresh() }
    }

    func refresh() async {
        if products.isEmpty { products = ((try? await Product.products(for: Self.productIDs)) ?? []).sorted { $0.price < $1.price } }
        var latest: String?
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, Self.productIDs.contains(t.productID), t.revocationDate == nil,
               (t.expirationDate ?? .distantFuture) > Date() { latest = result.jwsRepresentation }
        }
        jws = latest
        subscribed = latest != nil
        if subscribed { registerForPush() }
    }

    func buy(_ product: Product) async {
        busy = true
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let r):
                if case .verified(let t) = r { await t.finish() }
                await refresh()
                message = subscribed ? "Anywhere is on. You'll be told when a session needs you." : "The purchase didn't verify. Try Restore."
            case .pending: message = "Waiting for approval (Ask to Buy)."
            default: break
            }
        } catch { message = "The purchase didn't go through: \(error.localizedDescription)" }
    }

    func restore() async {
        busy = true
        defer { busy = false }
        try? await AppStore.sync()
        await refresh()
        message = subscribed ? "Anywhere is on." : "No Anywhere subscription found for this Apple ID."
    }

    func registerForPush() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    func didRegister(_ deviceToken: Data) {
        token = deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    /// What the connected Mac is given (kind 212); nil until there is a token and a subscription.
    var registration: PushRegistration? {
        guard let token, let jws else { return nil }
        return PushRegistration(token: token, env: env, jws: jws, name: UIDevice.current.name)
    }

    func sendTest() async {
        guard let token, let jws else { message = "Allow notifications first."; registerForPush(); return }
        busy = true
        defer { busy = false }
        var request = URLRequest(url: Self.server.appendingPathComponent("v1/test"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["device": token, "env": env, "jws": jws])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            message = code == 200 ? "Sent. It should arrive in a moment." : "Not sent: \(detail ?? "error \(code)")."
        } catch { message = "Not sent: \(error.localizedDescription)" }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let session = response.notification.request.content.userInfo["session"] as? String
        await MainActor.run {
            guard let session, !session.isEmpty else { return }
            if let open = openSession { open(session) } else { pendingSession = session }
        }
    }

    /// A session tapped before the shell was on screen.
    func takePendingSession() -> String? {
        defer { pendingSession = nil }
        return pendingSession
    }
}
