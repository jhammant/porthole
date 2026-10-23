import Foundation

/// Jon's favourite Mac apps, in his order, each with its ⌃⌥ letter (21 Oct 2026: "Can we have favourite
/// apps?"). He adds, removes, reorders and re-letters them from the sidebar (a long press). Pure: the list
/// and its rules; the app keeps it in UserDefaults (PortholeFavourites). Checked with swiftc
/// (Tests/checks/favourites).
struct PortholeFavouritesList: Codable, Equatable {
    struct App: Codable, Equatable {
        var bundleID: String
        var name: String
        /// One lowercase letter, or "" for none.
        var key: String
    }

    var apps: [App]

    /// Letters Porthole's own ⌃⌥ keys use, which a favourite never takes: S sidebar, B top bar, V agent
    /// view, T text, G tiles, J the next session that needs you, D the Desktop (23 Oct).
    static let reserved: Set<Character> = ["s", "b", "v", "t", "g", "j", "d"]

    /// The first list: seven common apps (Chrome, the Claude app, WhatsApp, Slack, Mail, Calendar, Finder).
    static let standard = PortholeFavouritesList(apps: [
        App(bundleID: "com.google.Chrome", name: "Google Chrome", key: "c"),
        App(bundleID: "com.anthropic.claudefordesktop", name: "Claude", key: "l"),
        App(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", key: "w"),
        App(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", key: "k"),
        App(bundleID: "com.apple.mail", name: "Mail", key: "m"),
        App(bundleID: "com.apple.iCal", name: "Calendar", key: "a"),
        App(bundleID: "com.apple.finder", name: "Finder", key: "f"),
    ])

    func contains(_ bundleID: String) -> Bool { apps.contains { $0.bundleID == bundleID } }

    /// The letters no favourite and nothing of Porthole's uses, a to z.
    func freeKeys() -> [Character] {
        let taken = Set(apps.compactMap(\.key.first))
        return "abcdefghijklmnopqrstuvwxyz".filter { !Self.reserved.contains($0) && !taken.contains($0) }
    }

    /// Added at the end, with the first free letter of its name, else the first free letter, else none.
    mutating func add(bundleID: String, name: String) {
        guard !contains(bundleID) else { return }
        let free = freeKeys()
        let letter = name.lowercased().first { free.contains($0) } ?? free.first
        apps.append(App(bundleID: bundleID, name: name, key: letter.map(String.init) ?? ""))
    }

    mutating func remove(_ bundleID: String) { apps.removeAll { $0.bundleID == bundleID } }

    /// One place up (-1) or down (+1); nothing past either end.
    mutating func move(_ bundleID: String, by step: Int) {
        guard let i = apps.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        let j = i + step
        guard j >= 0, j < apps.count else { return }
        apps.swapAt(i, j)
    }

    /// A new letter (nil: none). A letter Porthole reserves is refused; one another favourite has moves
    /// here, and that one gets this app's old letter.
    mutating func setKey(_ bundleID: String, to key: Character?) {
        guard let i = apps.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        guard let key = key.map({ Character($0.lowercased()) }) else { apps[i].key = ""; return }
        guard key.isLetter, !Self.reserved.contains(key) else { return }
        if let j = apps.firstIndex(where: { $0.key == String(key) }), j != i { apps[j].key = apps[i].key }
        apps[i].key = String(key)
    }

    func app(forKey characters: String) -> App? {
        guard characters.count == 1, let c = characters.lowercased().first, !Self.reserved.contains(c) else { return nil }
        return apps.first { $0.key == String(c) }
    }

    /// A list kept from before a letter became Porthole's (D, 23 Oct): that favourite loses the letter.
    func withoutReservedKeys() -> PortholeFavouritesList {
        var list = self
        for i in list.apps.indices where list.apps[i].key.first.map(Self.reserved.contains) == true { list.apps[i].key = "" }
        return list
    }
}
