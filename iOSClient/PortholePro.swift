import StoreKit
import SwiftUI

/// Porthole Pro (21 Oct 2026): a one-off purchase that unlocks the power features added after 1.0 (the
/// terminal theme first). Everything in 1.0 stays free. Built from source, Pro is simply on: only the App
/// Store's build (compiled with PORTHOLE_APPSTORE, Scripts/porthole-testflight.sh) asks StoreKit. DEBUG
/// `-PortholePro 0|1` sets it for a run.
@MainActor
final class PortholePro: ObservableObject {
    static let shared = PortholePro()
    static let productID = "io.hammant.porthole.pro"
    private static let cacheKey = "Porthole.proUnlocked"

    @Published private(set) var unlocked: Bool
    @Published private(set) var product: Product?
    @Published private(set) var busy = false
    @Published var paywallShown = false
    /// What the last purchase or restore said, for the sheet: nil while there is nothing to say.
    @Published private(set) var message: String?
    private var updates: Task<Void, Never>?

    static var storeBuild: Bool {
        #if PORTHOLE_APPSTORE
        return true
        #else
        return false
        #endif
    }

    private init() {
        unlocked = Self.storeBuild ? UserDefaults.standard.bool(forKey: Self.cacheKey) : true
        #if DEBUG
        if UserDefaults.standard.object(forKey: "PortholePro") != nil { unlocked = UserDefaults.standard.bool(forKey: "PortholePro") }
        #endif
        guard Self.storeBuild else { return }
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await self?.refresh()
            }
        }
        Task { await refresh() }
    }

    /// The product's price and whether this Apple ID owns Pro, from StoreKit.
    func refresh() async {
        guard Self.storeBuild else { return }
        if product == nil { product = try? await Product.products(for: [Self.productID]).first }
        var owned = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == Self.productID, t.revocationDate == nil { owned = true }
        }
        unlocked = owned
        UserDefaults.standard.set(owned, forKey: Self.cacheKey)
    }

    func buy() async {
        guard let product else { message = "The App Store didn't answer. Try again in a moment."; return }
        busy = true
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                if case .verified(let t) = result { await t.finish() }
                await refresh()
                message = unlocked ? "Thank you. Pro is on." : "The purchase didn't verify. Try Restore."
            case .pending: message = "Waiting for approval (Ask to Buy)."
            case .userCancelled: message = nil
            @unknown default: message = nil
            }
        } catch {
            message = "The purchase didn't go through: \(error.localizedDescription)"
        }
    }

    func restore() async {
        busy = true
        defer { busy = false }
        try? await AppStore.sync()
        await refresh()
        message = unlocked ? "Pro is on." : "No Pro purchase found for this Apple ID."
    }

    /// Runs `action` with Pro, else shows the sheet.
    func require(_ action: () -> Void) {
        if unlocked { action() } else { paywallShown = true }
    }
}

/// What Pro gives, the price, Buy and Restore.
struct PortholeProSheet: View {
    @ObservedObject var pro = PortholePro.shared
    @Environment(\.dismiss) private var dismiss

    static let features: [(String, String, String)] = [
        ("terminal", "Terminal theme", "Porthole itself drawn as a terminal UI, in your terminal's font."),
        ("macbook.and.iphone", "More to come", "Several Macs at once and other Mac apps as text, as they ship."),
        ("heart", "Keep it going", "Porthole stays free and open source; Pro pays for the work."),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Porthole Pro").font(.system(size: 30, weight: .bold))
                    Text("A one-off purchase. Everything Porthole does today stays free.")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                    ForEach(Self.features, id: \.1) { icon, title, detail in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: icon).font(.system(size: 20)).frame(width: 28).foregroundStyle(Palette.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(title).font(.system(size: 16, weight: .semibold))
                                Text(detail).font(.system(size: 14)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if pro.unlocked {
                        Label("Pro is on", systemImage: "checkmark.seal.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(.green)
                    } else {
                        Button { Task { await pro.buy() } } label: {
                            Text(pro.product.map { "Buy Pro · \($0.displayPrice)" } ?? "Buy Pro")
                                .font(.system(size: 17, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(.borderedProminent).disabled(pro.busy)
                        Button("Restore purchase") { Task { await pro.restore() } }.disabled(pro.busy)
                    }
                    if let m = pro.message { Text(m).font(.system(size: 14)).foregroundStyle(.secondary) }
                }
                .padding(24)
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .task { await pro.refresh() }
    }
}
