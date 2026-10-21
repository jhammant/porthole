/// Back and forward through what was on screen, as a browser's (Jon, 20 Oct 2026: "use a keyboard
/// shortcut to go forward and back with windows"; ⌃⌥← and ⌃⌥→). Not the flip list (⌃⌥Tab), which moves
/// whatever came on screen to its front: this keeps the order things were opened in, a place in it, and
/// what lies ahead of that place until something new opens. Pure, checked with swiftc
/// (Tests/checks/backforward).
struct PortholeBackForward<Item: Equatable> {
    private(set) var items: [Item] = []
    /// The place: the item on screen, or -1 before anything opened.
    private(set) var index = -1
    static var limit: Int { 50 }

    /// Something came on screen. Already the current item (back or forward just opened it): nothing
    /// changes. Else it follows the current item and what lay ahead goes, as a new page does in a browser.
    mutating func visit(_ item: Item) {
        if index >= 0, index < items.count, items[index] == item { return }
        if index + 1 < items.count { items.removeSubrange((index + 1)...) }
        items.append(item)
        if items.count > Self.limit { items.removeFirst(items.count - Self.limit) }
        index = items.count - 1
    }

    /// One step back (`by` -1) or forward (+1), past items that have gone (`isOpen` false: a window
    /// closed, a session ended). The place moves to it; nil, and the place stays, when there is none.
    mutating func step(_ by: Int, isOpen: (Item) -> Bool) -> Item? {
        guard by != 0 else { return nil }
        var i = index + by
        while i >= 0, i < items.count {
            if isOpen(items[i]) { index = i; return items[i] }
            i += by
        }
        return nil
    }
}
