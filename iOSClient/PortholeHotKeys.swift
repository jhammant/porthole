import SwiftUI
import UIKit

/// Porthole (docs/porthole-plan.md, Hot keys): shortcuts on a hardware keyboard, all with Control+Option,
/// since iPadOS keeps ⌘Tab and Mac apps rarely use ⌃⌥.
///
///   ⌃⌥Space   quick switcher           ⌃⌥J        the next session that needs you
///   ⌃⌥Tab     back to what was on screen before (a session or an app), ⌃⌥⇧Tab one further back
///   ⌃⌥↓ / ↑   next / previous window, down the sidebar (sessions, then apps); the header's Next window
///   ⌃⌥← / →   back / forward, as a browser's, through what was on screen (PortholeBackForward)
///   ⌃⌥1–9     the session in iTerm window 1–9 (else the nth)
///   ⌘` / ⌘⇧`  next / previous window of the app on screen
///   ⌃↓ / ⌃↑   App Exposé (the app's windows) / Mission Control (every window), as on the Mac (PortholeExpose)
///   ⌃⌥] / [   next / previous app      ⌃⌥G        one window, two tiles, four tiles
///   ⌃⌥S       show or hide the sidebar   ⌃⌥B        show or hide the top bar
///   ⌃⌥V       Claude Code's agent view as text   ⌃⌥T        a session as text or as its window
///   ⌃⌥D       the Desktop, and from the Desktop back to what was on screen before it
///   ⌃⌥ a letter       a favourite app (PortholeFavourites; at first C L W K M A F: Chrome, Claude,
///                     WhatsApp, Slack, Mail, Calendar, Finder), Jon's to change
///
/// Shaped by two weeks of real use: about 28 switches an hour, most of them flips between two
/// things, a Claude session and a browser page above all, so ⌃⌥Tab flips; ⌘` is his Mac habit. Each key
/// has a name, so holding ⌘ on the iPad lists them all (Jon, 17 Oct: "a really easy to see next window").
///
/// Two ways in, one way out: while the stream holds the keyboard, Porthole's InputOverlayView would pass
/// every key to the Mac, so it gives these to `claim` first (a `// Porthole:` hook in its pressesBegan);
/// anywhere else (the reply box) SwiftUI key commands catch them (`PortholeKeyCommands`). Both call
/// `fire`, which drops a second firing of the same action within 80 ms, so a key both paths see acts once.
enum PortholeHotKeys {
    enum Action: Equatable {
        case switcher, nextNeedingYou, nextSession, previousSession, session(Int)
        case nextWindow, previousWindow, nextAppWindow, previousAppWindow, nextApp, previousApp, tiles, sidebar, topBar
        case flip, flipFurther, app(String), back, forward, agentView, textMode, searchSessions, desktop
        case appExpose, missionControl
    }

    /// Set by the connected screen (PortholeShell).
    @MainActor static var handler: ((Action) -> Void)?
    @MainActor private static var last: (action: Action, at: CFAbsoluteTime)?
    /// Porthole (30 Oct): while the exposé is up, every key is offered to it first (down or up); true
    /// when it took the key, which then reaches neither a hot key nor the Mac.
    @MainActor static var modal: ((UIKey, Bool) -> Bool)?

    @MainActor static func fire(_ action: Action) {
        let now = CFAbsoluteTimeGetCurrent()
        if let last, last.action == action, now - last.at < 0.08 { return }
        last = (action, now)
        handler?(action)
    }

    /// The action for a key pressed with ⌃⌥ (⇧ only with Tab, no ⌘), or nil: the key is the Mac's.
    static func action(for key: UIKey) -> Action? {
        let flags = key.modifierFlags.intersection([.control, .alternate, .shift, .command])
        let shift = flags.contains(.shift)
        // ⌘` / ⌘⇧`: the Mac's own way through an app's windows.
        if flags.subtracting(.shift) == .command, key.keyCode == .keyboardGraveAccentAndTilde { return shift ? .previousAppWindow : .nextAppWindow }
        // ⌃↓ / ⌃↑: the Mac's App Exposé and Mission Control (30 Oct: "Same as the mac options").
        if flags == .control, key.keyCode == .keyboardDownArrow { return .appExpose }
        if flags == .control, key.keyCode == .keyboardUpArrow { return .missionControl }
        guard flags.contains(.control), flags.contains(.alternate), !flags.contains(.command) else { return nil }
        if !shift, let fav = PortholeFavourites.app(forKey: key.charactersIgnoringModifiers) { return .app(fav.bundleID) }
        switch key.keyCode {
        case .keyboardTab: return shift ? .flipFurther : .flip
        case _ where shift: return nil
        case .keyboardCloseBracket: return .nextApp
        case .keyboardOpenBracket: return .previousApp
        case .keyboardSpacebar: return .switcher
        case .keyboardSlash: return .searchSessions
        case .keyboardJ: return .nextNeedingYou
        case .keyboardRightArrow: return .forward
        case .keyboardLeftArrow: return .back
        case .keyboardDownArrow: return .nextWindow
        case .keyboardUpArrow: return .previousWindow
        case .keyboardG: return .tiles
        case .keyboardS: return .sidebar
        case .keyboardB: return .topBar
        case .keyboardV: return .agentView
        case .keyboardT: return .textMode
        case .keyboardD: return .desktop
        case .keyboard1: return .session(1)
        case .keyboard2: return .session(2)
        case .keyboard3: return .session(3)
        case .keyboard4: return .session(4)
        case .keyboard5: return .session(5)
        case .keyboard6: return .session(6)
        case .keyboard7: return .session(7)
        case .keyboard8: return .session(8)
        case .keyboard9: return .session(9)
        default: return nil
        }
    }

    /// Porthole (31 Oct, "The cmd shortcut didn't seem to do anything"): the shortcuts iPadOS has uses of its
    /// own for (⌘` steps through an app's windows there), as key commands asking for priority over the
    /// system, so they can reach Porthole before iPadOS takes them. The stream's input view and a session's
    /// text list them while first responder; `fire` drops a second firing within 80 ms, so a key that also
    /// reaches pressesBegan acts once.
    @MainActor static let priorityCommands: [UIKeyCommand] = [
        ("`", UIKeyModifierFlags.command), ("`", [.command, .shift]),
        (UIKeyCommand.inputDownArrow, .control), (UIKeyCommand.inputUpArrow, .control),
    ].map { input, flags in
        let command = UIKeyCommand(input: input, modifierFlags: flags, action: #selector(UIResponder.portholePriorityKey(_:)))
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    /// The action of one of `priorityCommands`.
    static func action(input: String?, flags: UIKeyModifierFlags) -> Action? {
        switch (input, flags.intersection([.control, .alternate, .shift, .command])) {
        case ("`", .command): return .nextAppWindow
        case ("`", [.command, .shift]): return .previousAppWindow
        case (UIKeyCommand.inputDownArrow, .control): return .appExpose
        case (UIKeyCommand.inputUpArrow, .control): return .missionControl
        default: return nil
        }
    }

    /// From InputOverlayView: the presses that are Porthole's, taken out of what goes to the Mac. Their
    /// actions fire on the way down; the way up only keeps the release from the Mac too.
    @MainActor static func claim(_ presses: Set<UIPress>, down: Bool) -> Set<UIPress> {
        guard handler != nil else { return [] }
        var mine: Set<UIPress> = []
        for press in presses {
            guard let key = press.key else { continue }
            if let modal, modal(key, down) { mine.insert(press); continue }
            guard let action = action(for: key) else { continue }
            mine.insert(press)
            if down { fire(action) }
        }
        return mine
    }
}

/// The same shortcuts as SwiftUI key commands, for when something other than the stream holds the
/// keyboard (the switcher's field), and named, so holding ⌘ lists them in iPadOS's shortcut overlay.
/// Invisible otherwise.
struct PortholeKeyCommands: View {
    /// Read so the favourites' keys follow Jon's edits.
    @AppStorage(PortholeFavourites.storageKey) private var favourites: Data?

    var body: some View {
        ZStack {
            key("Next window", .downArrow, .nextWindow)
            key("Previous window", .upArrow, .previousWindow)
            key("Back to the last thing", .tab, .flip)
            key("Back two", .tab, .flipFurther, shift: true)
            key("Find a window or app", .space, .switcher)
            key("Next session that needs you", "j", .nextNeedingYou)
            key("Back", .leftArrow, .back)
            key("Forward", .rightArrow, .forward)
            key("Next app", "]", .nextApp)
            key("Previous app", "[", .previousApp)
            Button("Next window of this app") { PortholeHotKeys.fire(.nextAppWindow) }.keyboardShortcut("`", modifiers: .command)
            Button("Previous window of this app") { PortholeHotKeys.fire(.previousAppWindow) }.keyboardShortcut("`", modifiers: [.command, .shift])
            Button("App Exposé") { PortholeHotKeys.fire(.appExpose) }.keyboardShortcut(.downArrow, modifiers: .control)
            Button("Mission Control") { PortholeHotKeys.fire(.missionControl) }.keyboardShortcut(.upArrow, modifiers: .control)
            key("Tiles", "g", .tiles)
            key("Show or hide the sidebar", "s", .sidebar)
            key("Show or hide the top bar", "b", .topBar)
            key("Agent view", "v", .agentView)
            key("Session as text or window", "t", .textMode)
            key("Search all sessions", "/", .searchSessions)
            key("Desktop", "d", .desktop)
            ForEach(PortholeFavourites.apps.filter { $0.key != nil }, id: \.bundleID) { fav in key(fav.name, KeyEquivalent(fav.key!), .app(fav.bundleID)) }
            ForEach(1...9, id: \.self) { n in key("Session \(n)", KeyEquivalent(Character("\(n)")), .session(n)) }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func key(_ title: String, _ key: KeyEquivalent, _ action: PortholeHotKeys.Action, shift: Bool = false) -> some View {
        Button(title) { PortholeHotKeys.fire(action) }
            .keyboardShortcut(key, modifiers: shift ? [.control, .option, .shift] : [.control, .option])
    }
}

/// Jon's favourite Mac apps with their ⌃⌥ letters (PortholeFavouritesList), kept on this device; the first
/// list is seven common apps. The sidebar's Your apps follows this order.
enum PortholeFavourites {
    static let storageKey = "Porthole.favourites"
    struct App { let bundleID: String; let name: String; let key: Character? }

    static var list: PortholeFavouritesList {
        get {
            guard let data = UserDefaults.standard.data(forKey: storageKey),
                  let list = try? JSONDecoder().decode(PortholeFavouritesList.self, from: data) else { return .standard }
            return list.withoutReservedKeys()
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: storageKey) }
    }

    static var apps: [App] { list.apps.map { App(bundleID: $0.bundleID, name: $0.name, key: $0.key.first) } }

    static func app(forKey characters: String) -> App? {
        list.app(forKey: characters).map { App(bundleID: $0.bundleID, name: $0.name, key: $0.key.first) }
    }

    static func edit(_ change: (inout PortholeFavouritesList) -> Void) {
        var l = list
        change(&l)
        list = l
    }
}

extension UIResponder {
    /// Porthole: one of `PortholeHotKeys.priorityCommands` reached this responder.
    @objc func portholePriorityKey(_ command: UIKeyCommand) {
        if let action = PortholeHotKeys.action(input: command.input, flags: command.modifierFlags) { PortholeHotKeys.fire(action) }
    }
}
