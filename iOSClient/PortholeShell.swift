import SwiftUI
import StreamProtocol

/// Porthole (docs/porthole-plan.md, iPad side): the connected screen. At a regular width (an iPad, the
/// iPhone Duo open), a sidebar of Claude Code sessions and Mac apps beside the Mac's own picture: a
/// session opens its iTerm window, an app its window, each fitted to the panel and looking exactly as it
/// does on the Mac. The divider drags; on the Duo open flat the fold is the divider. At a compact width
/// (an iPhone, the Duo's cover) the sidebar comes first and a pick opens its window, with Back.
struct PortholeShell: View {
    @ObservedObject var client: StreamClient
    @ObservedObject private var matrix = PortholeMatrix.shared
    @ObservedObject private var pro = PortholePro.shared
    @ObservedObject private var anywhere = PortholeAnywhere.shared
    @State private var pick: PortholePick = .apps
    @State private var sidebarShown = true
    @State private var switcherShown = false
    @State private var tilePickerShown = false
    @State private var compactPath: [PortholePick] = []
    /// The sidebar's width as last dragged (the divider), kept across launches.
    @AppStorage("Porthole.sidebarWidth") private var sidebarWidth: Double = 300
    /// StreamScreen's top bar hidden (⌃⌥B here, the tab there), kept across launches.
    @AppStorage(PortholeShell.topBarHiddenKey) private var topBarHidden = false
    static let topBarHiddenKey = "Porthole.topBarHidden"
    /// Sessions open as text (their iTerm screen in its own colours, docs/agent-view-plan.md) rather than
    /// as the streamed window: the Text | Window switch over a session, or ⌃⌥T. Kept across launches.
    @AppStorage("Porthole.sessionsAsText") private var sessionsAsText = false
    /// In text, the agent view beside the session, as two panes (21 Oct, the TUI options: "text by default
    /// with the agent view beside sessions").
    @AppStorage("Porthole.agentBeside") private var agentBeside = false
    @State private var dragStart: Double?
    @Environment(\.duoEnvironment) private var duoEnvironment
    @Environment(\.horizontalSizeClass) private var widthClass

    static let minSidebar: Double = 220
    /// Dragged narrower than this the sidebar hides; dragged out again from the edge it comes back.
    static let hideBelow: Double = 140

    var body: some View {
        GeometryReader { geo in
            let posture = DuoPosture.read(geo, duoEnvironment)
            let compact = widthClass == .compact || geo.size.width < 700
            ZStack {
                if compact {
                    compactBody
                } else {
                    HStack(spacing: 0) {
                        if sidebarShown {
                            PortholeSidebar(client: client, pick: pick, open: open, onTiles: { tilePickerShown = true },
                                            onNext: { handle(.nextWindow) },
                            sessionsMode: !sessionsAsText ? .window : agentBeside ? .textWithAgent : .text, setMode: setSessionsMode)
                                .frame(width: sidebarFrame(geo.size, posture))
                        }
                        divider(geo.size, posture).zIndex(1)
                        detail
                            // Over the content, not the sidebar: on the Duo open flat, the right half.
                            .overlay { if switcherShown { PortholeSwitcher(client: client, shown: $switcherShown, open: open) } }
                    }
                }
                if compact && switcherShown {
                    PortholeSwitcher(client: client, shown: $switcherShown, open: open)
                }
            }
        }
        .background(PortholeStyle.ground.ignoresSafeArea())
        // No status bar over the sidebar's first row: iPadOS drew it there without a safe area (Info.plist
        // asks for none), and Jon wants no room wasted.
        .statusBarHidden(true)
        .sheet(isPresented: $pro.paywallShown) { PortholeProSheet() }
        // The hidden matrix mode's way in (PortholeMatrix).
        .overlay { if let at = matrix.introAt { PortholeMatrixIntro(start: at) } }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $tilePickerShown) {
            PortholeTilePicker(client: client, shown: $tilePickerShown) { ids in client.select(.tiles(ids)); open(.apps) }
        }
        .onAppear {
            PortholeHotKeys.handler = { action in handle(action) }
            // Porthole Anywhere: a tapped notification opens its session; the Mac gets this device's token.
            anywhere.openSession = { id in if client.porthole.session(id) != nil { open(.session(id)) } }
            if let id = anywhere.takePendingSession() { anywhere.openSession?(id) }
            if let r = anywhere.registration { client.sendPushRegistration(r) }
        }
        .onChange(of: anywhere.registration) { _, r in if let r { client.sendPushRegistration(r) } }
        .onChange(of: client.connected) { _, up in if up, let r = anywhere.registration { client.sendPushRegistration(r) } }
        #if DEBUG
        // -PortholeOpen needs|first: open a session's window once the list arrives, for the simulator
        // runs (docs/porthole-plan.md, Judges) that have no hand to tap with.
        .onChange(of: client.porthole.sessions.isEmpty, initial: true) { _, empty in
            guard !empty, pick == .apps, let how = UserDefaults.standard.string(forKey: "PortholeOpen") else { return }
            // agent: the agent view; window:ID that window; desktop the Desktop (the store's screenshots).
            if how == "agent" { open(.agentView); return }
            if how == "desktop" { client.select(.desktop); return }
            if how.hasPrefix("window:"), let id = UInt32(how.dropFirst(7)) { client.show(window: id); return }
            // needs, first, or any other word: the first session whose folder or title has it.
            let named = client.porthole.sessions.first { $0.folder.localizedCaseInsensitiveContains(how) || $0.title.localizedCaseInsensitiveContains(how) }
            let s = how == "needs" ? (client.porthole.needsYou.first ?? client.porthole.sessions.first)
                : how == "first" ? client.porthole.sessions.first : named
            if let s { open(.session(s.id)) }
        }
        // -PortholeTiles 2|4: tile the most recent windows a few seconds after connecting (simulator runs;
        // the list has usually arrived before this screen appears, so a change of it can't be the trigger).
        .task {
            let n = UserDefaults.standard.integer(forKey: "PortholeTiles")
            guard n >= 2 else { return }
            try? await Task.sleep(for: .seconds(5))
            if client.recentWindows.count >= n { client.select(.tiles(Array(client.recentWindows.prefix(n).map(\.id)))) }
        }
        #endif
        .background(PortholeKeyCommands())
    }

    /// On the Duo open flat or as a book the fold is the divider: each half about a phone's width.
    static func foldDivides(_ size: CGSize, _ posture: DuoPosture) -> Bool {
        posture.pose(size) == .flatLandscape || posture.pose(size) == .book
    }

    static func clampedWidth(_ width: Double, in total: CGFloat) -> Double {
        min(max(width, minSidebar), Double(total) * 0.6)
    }

    private func sidebarFrame(_ size: CGSize, _ posture: DuoPosture) -> CGFloat {
        if Self.foldDivides(size, posture) { return (size.width / 2).rounded(.down) }
        return CGFloat(Self.clampedWidth(sidebarWidth, in: size.width))
    }

    /// The line between the sidebar and the window. Drag it to resize the sidebar (narrower than
    /// `hideBelow` hides it, and dragging out from the edge brings it back); double-tap to hide or show.
    /// The window refits to the new width once the drag settles (StreamScreen's viewport). Fixed on the fold.
    @ViewBuilder private func divider(_ size: CGSize, _ posture: DuoPosture) -> some View {
        if Self.foldDivides(size, posture) {
            if sidebarShown { Rectangle().fill(PortholeStyle.line).frame(width: 1) }
        } else {
            PortholeDivider(dragging: dragStart != nil)
                .gesture(dividerDrag(size))
                .onTapGesture(count: 2) { withAnimation(.easeOut(duration: 0.18)) { sidebarShown.toggle() } }
                // Hidden, the sidebar's way back was the 1 pt edge alone, which Jon could only find by
                // double-tapping it ("not good enough", 20 Oct): a tab on the edge, tapped or pulled.
                .overlay(alignment: .leading) {
                    if !sidebarShown {
                        PortholeSidebarTab()
                            .gesture(dividerDrag(size))
                            .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { sidebarShown = true } }
                    }
                }
        }
    }

    private func dividerDrag(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { g in
                let start = dragStart ?? (sidebarShown ? Self.clampedWidth(sidebarWidth, in: size.width) : 0)
                if dragStart == nil { dragStart = start }
                let width = start + Double(g.translation.width)
                if width < Self.hideBelow {
                    sidebarShown = false
                } else {
                    sidebarShown = true
                    sidebarWidth = Self.clampedWidth(width, in: size.width)
                }
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Always the Mac's own picture (Porthole's stream screen): an app's window, or a session's iTerm window
    /// exactly as it looks on the Mac, fitted to the panel.
    @ViewBuilder private var detail: some View {
        if pick == .agentView {
            PortholeTerminalPane(client: client, terminalID: PortholeShell.agentViewID)
        } else if sessionsAsText, let id = pick.sessionID, let s = client.porthole.session(id), let terminal = s.terminalID {
            if agentBeside {
                HStack(spacing: 0) {
                    PortholeTerminalPane(client: client, terminalID: terminal, windowID: s.windowID, title: s.title)
                        .id(terminal)
                    Rectangle().fill(PortholeStyle.line).frame(width: 1)
                    PortholeTerminalPane(client: client, terminalID: PortholeShell.agentViewID)
                }
            } else {
                PortholeTerminalPane(client: client, terminalID: terminal, windowID: s.windowID, title: s.title)
                    .id(terminal)
            }
        } else {
            StreamScreen(client: client).overlay(alignment: .top) { noticeBanner }
        }
    }

    /// The host's terminal id for Claude Code's agent view (PortholeAgentViews on the Mac).
    static let agentViewID = "agent-view"

    /// The Mac's notice over the picture (screen capture refused, and how to get it back).
    @ViewBuilder private var noticeBanner: some View {
        if let text = client.porthole.notice?.text {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PortholeStyle.brass)
                Text(text).font(PortholeType.ui(13)).foregroundStyle(PortholeStyle.text).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(PortholeStyle.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(PortholeStyle.brass.opacity(0.5)))
            .padding(14)
            .accessibilityElement(children: .combine)
        }
    }

    /// iPhone, the Duo's cover, the Duo half open (with the keyboard filling the lower half): a stack.
    /// The sidebar first; a session or an app opens its window, with Back.
    private var compactBody: some View {
        NavigationStack(path: $compactPath) {
            PortholeSidebar(client: client, pick: pick, open: open, onTiles: { tilePickerShown = true },
                            onNext: { handle(.nextWindow) },
                            sessionsMode: !sessionsAsText ? .window : agentBeside ? .textWithAgent : .text, setMode: setSessionsMode)
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: PortholePick.self) { _ in
                    detail.navigationBarTitleDisplayMode(.inline)
                }
        }
        .onChange(of: compactPath) { _, path in if path.isEmpty { pick = .apps } }
    }

    // MARK: Picking

    private func open(_ p: PortholePick) {
        #if DEBUG
        print("porthole: open \(p)")
        #endif
        pick = p
        compactPath = [p]   // the narrow layout's stack shows what was opened
        if case .session(let id) = p, let window = client.porthole.session(id)?.windowID {
            client.porthole.remember(.session(id))
            // As text, the session's screen comes as text: the picture stays as it was, sparing the link.
            if !sessionsAsText { client.show(window: window, remember: false) }
        }
    }

    /// Window, text, or text with the agent view beside it, for sessions (PortholeTextSwitch).
    private func setSessionsMode(_ mode: PortholeTextSwitch.Mode) {
        agentBeside = mode == .textWithAgent
        setSessionsAsText(mode != .window)
    }

    /// Text or window for sessions; the session on screen switches with it.
    private func setSessionsAsText(_ text: Bool) {
        sessionsAsText = text
        if !text, let id = pick.sessionID, let window = client.porthole.session(id)?.windowID {
            client.show(window: window, remember: false)
        }
    }

    /// A window from the walk, a flip or ⌘`: its session's row when it is a session's iTerm window.
    private func openWindow(_ id: UInt32) {
        if let s = client.porthole.sessions.first(where: { $0.windowID == id }) {
            open(.session(s.id))
        } else {
            client.show(window: id)
            open(.apps)
        }
    }

    /// What is on screen as a source: the picked session's window (shown as its window or as text), else
    /// what streams.
    private var onScreen: StreamSource {
        if let id = pick.sessionID, let w = client.porthole.session(id)?.windowID { return .window(w) }
        return client.active
    }

    private func handle(_ action: PortholeHotKeys.Action) {
        let current = pick.sessionID
        switch action {
        case .nextSession, .previousSession:
            if let s = client.porthole.session(after: current, by: action == .nextSession ? 1 : -1) { open(.session(s.id)) }
        case .nextNeedingYou:
            if let s = client.porthole.nextNeedingYou(after: current) { open(.session(s.id)) }
        case .session(let n):
            let byNumber = client.porthole.sessions.first { $0.windowNumber == n }
            let byOrder = n - 1 < client.porthole.sessions.count ? client.porthole.sessions[n - 1] : nil
            if let s = byNumber ?? byOrder { open(.session(s.id)) }
        case .nextWindow, .previousWindow:
            // From what is on screen: a session shown as text doesn't stream its window, so the walk starts
            // from that session's window, not from the last window streamed (stuck on one session, 21 Oct).
            if let id = PortholeSidebar.step(from: onScreen, in: PortholeSidebar.windowOrder(client),
                                             by: action == .nextWindow ? 1 : -1) { openWindow(id) }
        case .nextAppWindow, .previousAppWindow:
            if let w = PortholeApps.window(after: onScreen, in: client.windows, sameApp: true,
                                           step: action == .nextAppWindow ? 1 : -1) { openWindow(w.id) }
        case .nextApp, .previousApp:
            if let w = PortholeApps.window(after: onScreen, in: PortholeSidebar.appWindows(client), sameApp: false,
                                           step: action == .nextApp ? 1 : -1) { openWindow(w.id) }
        case .back, .forward:
            let gone: (PortholeHistoryItem) -> Bool = { item in
                switch item {
                case .session(let id): return client.porthole.session(id) == nil
                case .window(let id): return !client.windows.contains { $0.id == id }
                }
            }
            switch client.porthole.backForward.step(action == .back ? -1 : 1, isOpen: { !gone($0) }) {
            case .session(let id): open(.session(id))
            case .window(let id): openWindow(id)
            case nil: break
            }
        case .flip, .flipFurther:
            let depth = action == .flip ? 1 : 2
            let history = client.porthole.history
            guard history.count > depth else { return }
            switch history[depth] {
            case .session(let id) where client.porthole.session(id) != nil: open(.session(id))
            case .window(let id) where client.windows.contains(where: { $0.id == id }): openWindow(id)
            default: break
            }
        case .app(let bundleID):
            if let w = client.recentWindows.first(where: { $0.bundleID == bundleID }) { client.show(window: w.id) } else { client.launch(bundleID: bundleID) }
            open(.apps)
        case .tiles:
            if let next = PortholeTilePicker.next(after: client.active, windows: client.recentWindows) { client.select(next); open(.apps) }
        case .sidebar:
            withAnimation(.easeOut(duration: 0.18)) { sidebarShown.toggle() }
        case .agentView:
            open(pick == .agentView ? .apps : .agentView)
        case .textMode:
            setSessionsAsText(!sessionsAsText)
        case .topBar:
            withAnimation(.easeOut(duration: 0.18)) { topBarHidden.toggle() }
        case .switcher:
            switcherShown.toggle()
        }
    }
}

/// The sidebar's edge: a hairline that thickens under the pointer or a finger, with a wider grab area
/// laid over the window beside it, so it takes no room from the picture.
struct PortholeDivider: View {
    let dragging: Bool
    @State private var hovering = false

    var body: some View {
        let lit = dragging || hovering
        Rectangle().fill(lit ? PortholeStyle.blue.opacity(0.8) : PortholeStyle.line)
            .frame(width: lit ? 3 : 1)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear.frame(width: 14).contentShape(Rectangle())
                    .onHover { hovering = $0 }
            }
            .accessibilityElement()
            .accessibilityLabel("Sidebar edge")
            .accessibilityHint("Drag to resize the sidebar. Double-tap to hide or show it.")
    }
}

/// The hidden sidebar's handle on the left edge: tap to show the sidebar, or pull it out.
struct PortholeSidebarTab: View {
    var body: some View {
        Image(systemName: "chevron.compact.right")
            .font(PortholeType.ui(18, .semibold))
            .foregroundStyle(PortholeStyle.text)
            .frame(width: 22, height: 72)
            .background(PortholeStyle.panel, in: UnevenRoundedRectangle(bottomTrailingRadius: 10, topTrailingRadius: 10))
            .overlay(UnevenRoundedRectangle(bottomTrailingRadius: 10, topTrailingRadius: 10).stroke(PortholeStyle.line))
            .frame(width: 44, height: 96, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityLabel("Show sidebar")
            .accessibilityAddTraits(.isButton)
    }
}

/// The top bar's handle on the picture's top edge: a chevron up to hide the bar, down to bring it back.
struct PortholeTopBarTab: View {
    let hidden: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: hidden ? "chevron.compact.down" : "chevron.compact.up")
                .font(PortholeType.ui(16, .semibold))
                .foregroundStyle(PortholeStyle.text.opacity(0.85))
                .frame(width: 64, height: 16)
                .background(PortholeStyle.panel.opacity(0.9), in: UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8))
                .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8).stroke(PortholeStyle.line))
                .frame(width: 88, height: 28, alignment: .top)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hidden ? "Show the top bar" : "Hide the top bar")
    }
}

enum PortholePick: Hashable {
    case apps
    case session(String)
    /// Claude Code's agent view as text (docs/agent-view-plan.md).
    case agentView
    var sessionID: String? { if case .session(let id) = self { return id } else { return nil } }
}

/// The Aa scale every window fits at (StreamScreen's `textScale`): 1.0 until Jon picks another, then his
/// pick, on every window and every launch; 0 stored means he turned fitting off. Porthole starts each screen
/// at none, which leaves windows at their Mac size; Porthole fits them to the iPad from the start
/// (Jon, 17 Oct 2026: "it needs to auto resize to the viewport size on my iPad").
enum PortholeFit {
    static let key = "Porthole.textScale"
    static var savedScale: Double? {
        let v = UserDefaults.standard.object(forKey: key) as? Double ?? 1.0
        return v > 0 ? v : nil
    }
    static func save(_ scale: Double?) { UserDefaults.standard.set(scale ?? 0, forKey: key) }
}

/// The look (docs/porthole-plan.md; the Duo mockup): dark, brass only for what needs Jon, blue for
/// working.
enum PortholeStyle {
    static let ground = Color(red: 0x0B / 255, green: 0x11 / 255, blue: 0x17 / 255)
    static let panel = Color(red: 0x0E / 255, green: 0x15 / 255, blue: 0x1C / 255)
    static let line = Color(red: 0x1C / 255, green: 0x27 / 255, blue: 0x32 / 255)
    static let field = Color(red: 0x11 / 255, green: 0x1A / 255, blue: 0x22 / 255)
    static let selected = Color(red: 0x23 / 255, green: 0x31 / 255, blue: 0x3E / 255)
    static let text = Color(red: 0xE6 / 255, green: 0xED / 255, blue: 0xF3 / 255)
    static let soft = Color(red: 0xC9 / 255, green: 0xD1 / 255, blue: 0xD9 / 255)
    static let muted = Color(red: 0x9A / 255, green: 0xA7 / 255, blue: 0xB4 / 255)
    static let label = Color(red: 0x8F / 255, green: 0xA2 / 255, blue: 0xB5 / 255)
    static let brass = Color(red: 0xE8 / 255, green: 0xA3 / 255, blue: 0x3D / 255)
    static let blue = Color(red: 0x5A / 255, green: 0xA9 / 255, blue: 0xFF / 255)
    static let green = Color(red: 0x4C / 255, green: 0xC3 / 255, blue: 0x8A / 255)

    /// "26 min", "3 h", "2 d" since `since` (seconds since 1970).
    static func waited(_ since: Double?, now: Date = Date()) -> String? {
        guard let since else { return nil }
        let s = max(0, now.timeIntervalSince1970 - since)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60)) min" }
        if s < 86_400 { return "\(Int(s / 3600)) h" }
        return "\(Int(s / 86_400)) d"
    }
}

/// Mac windows in the host's order (front to back, which is recent use), grouped by app.
enum PortholeApps {
    struct App: Identifiable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        let windows: [WindowInfo]
    }

    static func apps(_ windows: [WindowInfo]) -> [App] {
        var order: [String] = []
        var groups: [String: [WindowInfo]] = [:]
        for w in windows {
            if groups[w.bundleID] == nil { order.append(w.bundleID) }
            groups[w.bundleID, default: []].append(w)
        }
        return order.map { App(bundleID: $0, name: groups[$0]!.first!.appName, windows: groups[$0]!) }
    }

    /// The next window after what streams: in the same app (⌘`), or the first window of the next app in
    /// the given order (⌃⌥] [), wrapping round.
    static func window(after active: StreamSource, in windows: [WindowInfo], sameApp: Bool, step: Int) -> WindowInfo? {
        guard !windows.isEmpty else { return nil }
        var currentID: UInt32?
        if case .window(let id) = active { currentID = id }
        let current = windows.first { $0.id == currentID }
        if sameApp {
            guard let current else { return windows.first }
            let mine = windows.filter { $0.bundleID == current.bundleID }
            guard let i = mine.firstIndex(where: { $0.id == current.id }), mine.count > 1 else { return nil }
            return mine[((i + step) % mine.count + mine.count) % mine.count]
        }
        let list = apps(windows)
        guard let current, let i = list.firstIndex(where: { $0.bundleID == current.bundleID }) else { return list.first?.windows.first }
        return list[((i + step) % list.count + list.count) % list.count].windows.first
    }
}

// MARK: - The sidebar

struct PortholeSidebar: View {
    @ObservedObject var client: StreamClient
    let pick: PortholePick
    let open: (PortholePick) -> Void
    var onTiles: () -> Void = {}
    /// The header's Next window button (⌃⌥↓).
    var onNext: () -> Void = {}
    /// Sessions as their windows, as text, or as text with the agent view beside (PortholeTextSwitch, ⌃⌥T).
    var sessionsMode: PortholeTextSwitch.Mode = .window
    var setMode: (PortholeTextSwitch.Mode) -> Void = { _ in }
    @State private var expanded: Set<String> = []
    @State private var allAppsShown = false
    /// Read so Your apps follows Jon's edits (PortholeFavourites).
    @AppStorage(PortholeFavourites.storageKey) private var favourites: Data?
    @ObservedObject private var matrix = PortholeMatrix.shared
    @ObservedObject private var pro = PortholePro.shared
    /// The Pro terminal theme (PortholeType); read so the sidebar redraws in it.
    @AppStorage(PortholeType.themeKey) private var tuiTheme = false
    /// Text modes in dark or light colours (StreamClient.textColours).
    @AppStorage(StreamClient.textColoursKey) private var textColours = "dark"

    var body: some View {
        let sessions = client.porthole.sessions
        VStack(spacing: 0) {
            header.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        agentViewRow
                        PortholeTextSwitch(mode: sessionsMode, set: setMode)
                        PortholeColoursSwitch(colours: textColours) { c in
                            textColours = c
                            // The text on screen comes again in the new colours.
                            for id in client.porthole.terminalPanes.keys {
                                let w = client.porthole.sessions.first { $0.terminalID == id }?.windowID
                                let state = client.porthole.terminals[id]
                                client.watchTerminal(id, windowID: w, fit: state.map { ($0.columns, $0.rows) })
                            }
                        }
                        section("Needs you", count: client.porthole.needsYou.count, color: PortholeStyle.brass,
                                sessions.filter { $0.state == .needsYou })
                        section("Working", count: nil, color: PortholeStyle.label, sessions.filter { $0.state == .working })
                        section("Done", count: nil, color: PortholeStyle.label, sessions.filter { $0.state == .done || $0.state == .idle })
                        favouritesSection
                        appsSection
                        proRow
                        keysHint
                    }
                    .padding(.horizontal, 10).padding(.bottom, 12)
                }
                // Keep what streams in view as ⌃⌥↓ walks down the list.
                .onChange(of: client.active) { _, active in
                    guard case .window(let id) = active, let row = Self.row(showing: id, client) else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(row) }
                }
            }
        }
        .background(ZStack { PortholeStyle.panel; if matrix.on { PortholeMatrixRain(opacity: 0.22) } })
        .sheet(isPresented: $allAppsShown) { PortholeAllApps(client: client, shown: $allAppsShown) }
    }

    /// One row: the Mac, and Next window, always in sight with its key.
    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(client.connected ? PortholeStyle.green : PortholeStyle.muted).frame(width: 7, height: 7)
            Text(client.macName.isEmpty ? "Connecting…" : client.macName)
                .font(PortholeType.ui(13, .semibold)).foregroundStyle(PortholeStyle.text).lineLimit(1)
                .onTapGesture(count: 5) { PortholeMatrix.shared.toggle() }
            if client.demo {
                Button("Leave demo") { client.stopDemo() }
                    .font(PortholeType.ui(12, .medium)).buttonStyle(.plain).foregroundStyle(PortholeStyle.brass)
            }
            Spacer(minLength: 6)
            Button(action: onNext) {
                HStack(spacing: 6) {
                    Text("Next window").font(PortholeType.ui(12.5, .medium))
                    Text("⌃⌥↓").font(PortholeType.ui(11.5, mono: true)).foregroundStyle(PortholeStyle.muted)
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(PortholeStyle.field, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(PortholeStyle.line))
            }
            .buttonStyle(.plain).foregroundStyle(PortholeStyle.text)
            .accessibilityHint("Control Option Down Arrow")
        }
    }

    /// Claude Code's agent view as text: background sessions, sharp at any link speed (⌃⌥V).
    private var agentViewRow: some View {
        let selected = pick == .agentView
        return Button { open(selected ? .apps : .agentView) } label: {
            HStack(spacing: 10) {
                Image(systemName: "terminal").font(PortholeType.ui(14, .medium)).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent view").font(PortholeType.ui(14.5, .medium)).foregroundStyle(PortholeStyle.text)
                    Text("Claude Code, as text · background sessions").font(PortholeType.ui(11.5)).foregroundStyle(PortholeStyle.muted)
                }
                Spacer(minLength: 6)
                Text("⌃⌥V").font(PortholeType.ui(11.5, mono: true)).foregroundStyle(PortholeStyle.muted)
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
            .background(selected ? PortholeStyle.field : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(PortholeStyle.text)
        .padding(.top, 4)
    }

    /// Porthole Pro's switches (PortholePro): the terminal theme; without Pro, a tap opens the Pro sheet.
    private var proRow: some View {
        Button {
            pro.require { tuiTheme.toggle() }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "terminal").font(PortholeType.ui(15)).frame(width: 24, height: 24)
                Text("Terminal theme").font(PortholeType.ui(13.5))
                Spacer()
                if pro.unlocked {
                    Image(systemName: tuiTheme ? "checkmark.circle.fill" : "circle").foregroundStyle(tuiTheme ? PortholeStyle.green : PortholeStyle.muted)
                } else {
                    Text("PRO").font(PortholeType.ui(10.5, .semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(PortholeStyle.brass.opacity(0.25), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(PortholeStyle.brass)
                }
            }
            .foregroundStyle(PortholeStyle.soft)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .accessibilityLabel(pro.unlocked ? "Terminal theme, \(tuiTheme ? "on" : "off")" : "Terminal theme, a Porthole Pro feature")
    }

    /// The keys worth knowing, at the foot of the list; holding ⌘ shows every one (PortholeKeyCommands).
    private var keysHint: some View {
        Text("⌃⌥↓ ↑ next or previous window · ⌃⌥← → back or forward · ⌃⌥V agent view · ⌃⌥Space find · hold ⌘ for every key")
            .font(PortholeType.ui(11)).foregroundStyle(PortholeStyle.muted)
            .padding(.top, 16).padding(.horizontal, 6)
    }

    @ViewBuilder
    private func section(_ title: String, count: Int?, color: Color, _ list: [ClaudeSession]) -> some View {
        if !list.isEmpty {
            HStack(spacing: 8) {
                Text(PortholeType.tui ? "┌─ " + title.uppercased() + " ─" : title.uppercased()).font(PortholeType.ui(11, .semibold)).tracking(PortholeType.tui ? 0 : 1.2)
                if let count { Text("\(count)").font(PortholeType.ui(11, mono: true)) }
            }
            .foregroundStyle(color)
            .padding(.top, 10).padding(.bottom, 4).padding(.horizontal, 6)
            ForEach(list) { s in row(s) }
        }
    }

    private func row(_ s: ClaudeSession) -> some View {
        let selected = pick.sessionID == s.id
        let needs = s.state == .needsYou
        let windowless = s.windowID == nil
        return Button { open(.session(s.id)) } label: {
            HStack(alignment: .top, spacing: 11) {
                PortholeStateDot(state: s.state).padding(.top, needs ? 5 : 4)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(s.title).font(.system(size: needs ? 14 : 13.5, weight: needs ? .medium : .regular))
                            .foregroundStyle(PortholeStyle.text).lineLimit(1)
                        Spacer(minLength: 6)
                        if needs, let w = PortholeStyle.waited(s.since) {
                            Text(w).font(PortholeType.ui(11, mono: true)).foregroundStyle(PortholeStyle.brass)
                        }
                    }
                    Text(windowless ? "\(s.portal) · runs in the background, no window" : s.portal)
                        .font(PortholeType.ui(11.5)).foregroundStyle(PortholeStyle.muted)
                    if needs, let p = s.preview {
                        Text(p).font(PortholeType.ui(12.5)).foregroundStyle(PortholeStyle.soft).lineLimit(2)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, needs ? 10 : 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? (needs ? PortholeStyle.brass.opacity(0.12) : PortholeStyle.selected) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(selected && needs ? PortholeStyle.brass.opacity(0.35) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(windowless)
        .opacity(windowless ? 0.55 : 1)
        .accessibilityLabel("\(s.title), \(s.portal), \(Self.stateWords(s))")
    }

    /// The favourite apps (PortholeFavourites), open or not, each a tap or ⌃⌥ letter away.
    private var favouritesSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("YOUR APPS").font(PortholeType.ui(11, .semibold)).tracking(1.2).foregroundStyle(PortholeStyle.label)
                .padding(.top, 12).padding(.bottom, 4).padding(.horizontal, 6)
            ForEach(PortholeFavourites.apps, id: \.bundleID) { fav in
                let windows = client.recentWindows.filter { $0.bundleID == fav.bundleID }
                Button {
                    if let w = windows.first { client.show(window: w.id) } else { client.launch(bundleID: fav.bundleID) }
                    open(.apps)
                } label: {
                    HStack(spacing: 11) {
                        if let icon = client.icons[fav.bundleID] {
                            Image(uiImage: icon).resizable().frame(width: 24, height: 24)
                        } else {
                            RoundedRectangle(cornerRadius: 6).fill(PortholeStyle.field).frame(width: 24, height: 24)
                        }
                        Text(fav.name).font(PortholeType.ui(13.5)).foregroundStyle(windows.isEmpty ? PortholeStyle.muted : PortholeStyle.text)
                        Spacer(minLength: 6)
                        if windows.count > 1 { Text("\(windows.count)").font(PortholeType.ui(11.5)).foregroundStyle(PortholeStyle.muted) }
                        if let key = fav.key {
                            Text("⌃⌥" + String(key).uppercased()).font(PortholeType.ui(11, mono: true)).foregroundStyle(PortholeStyle.muted)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(windows.contains { client.active == .window($0.id) } && pick == .apps ? PortholeStyle.selected : .clear,
                                in: RoundedRectangle(cornerRadius: 11))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { favouriteMenu(fav) }
                .accessibilityLabel(windows.isEmpty ? "Open \(fav.name)" : "\(fav.name), \(windows.count) windows")
                if fav.bundleID == PortholeBrowserIDs.chrome, let tabs = client.porthole.browserTabs, !tabs.windows.isEmpty {
                    chromeTabs(tabs)
                }
            }
        }
    }

    /// A favourite's long press: move it, give it another ⌃⌥ letter, or take it off the list.
    @ViewBuilder
    private func favouriteMenu(_ fav: PortholeFavourites.App) -> some View {
        let list = PortholeFavourites.list
        let index = list.apps.firstIndex { $0.bundleID == fav.bundleID } ?? 0
        if index > 0 {
            Button { PortholeFavourites.edit { $0.move(fav.bundleID, by: -1) } } label: { Label("Move up", systemImage: "arrow.up") }
        }
        if index < list.apps.count - 1 {
            Button { PortholeFavourites.edit { $0.move(fav.bundleID, by: 1) } } label: { Label("Move down", systemImage: "arrow.down") }
        }
        Menu {
            ForEach(list.freeKeys().map(String.init) + (fav.key.map { [String($0)] } ?? []), id: \.self) { letter in
                Button("⌃⌥" + letter.uppercased()) { PortholeFavourites.edit { $0.setKey(fav.bundleID, to: Character(letter)) } }
            }
            Button("No key") { PortholeFavourites.edit { $0.setKey(fav.bundleID, to: nil) } }
        } label: { Label(fav.key.map { "Key: ⌃⌥" + String($0).uppercased() } ?? "Give it a key", systemImage: "keyboard") }
        Button(role: .destructive) { PortholeFavourites.edit { $0.remove(fav.bundleID) } } label: {
            Label("Remove from favourites", systemImage: "star.slash")
        }
    }

    /// Chrome's tabs under its row, window by window (the active tab marked): a tap brings the tab
    /// forward and streams its window. Collapsed to each window's active tab until opened.
    @ViewBuilder
    private func chromeTabs(_ tabs: BrowserTabs) -> some View {
        let open = expanded.contains(PortholeBrowserIDs.chrome)
        Button {
            if open { expanded.remove(PortholeBrowserIDs.chrome) } else { expanded.insert(PortholeBrowserIDs.chrome) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(PortholeType.ui(10))
                Text(open ? "Hide tabs" : "\(tabs.windows.reduce(0) { $0 + $1.tabs.count }) tabs").font(PortholeType.ui(12))
            }
            .foregroundStyle(PortholeStyle.muted)
            .padding(.leading, 47).padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        ForEach(Array(tabs.windows.enumerated()), id: \.offset) { _, window in
            ForEach(open ? window.tabs : window.tabs.filter(\.active)) { tab in
                Button { client.open(tab: tab, in: window); self.open(.apps) } label: {
                    HStack(spacing: 8) {
                        Circle().fill(tab.active ? PortholeStyle.soft : Color.clear).frame(width: 5, height: 5)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tab.title).font(PortholeType.ui(12.5)).foregroundStyle(PortholeStyle.soft).lineLimit(1)
                            if open { Text(PortholeBrowserIDs.host(tab.url)).font(PortholeType.ui(10.5)).foregroundStyle(PortholeStyle.muted).lineLimit(1) }
                        }
                    }
                    .padding(.leading, 47).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("OTHER APPS").font(PortholeType.ui(11, .semibold)).tracking(1.2).foregroundStyle(PortholeStyle.label)
                .padding(.top, 12).padding(.bottom, 4).padding(.horizontal, 6)
            ForEach(Self.otherApps(client)) { app in
                Button {
                    if let w = client.recentWindows.first(where: { $0.bundleID == app.bundleID }) ?? app.windows.first { client.show(window: w.id) }
                    open(.apps)
                } label: {
                    HStack(spacing: 11) {
                        if let icon = client.icons[app.bundleID] {
                            Image(uiImage: icon).resizable().frame(width: 24, height: 24)
                        } else {
                            RoundedRectangle(cornerRadius: 6).fill(PortholeStyle.field).frame(width: 24, height: 24)
                        }
                        Text(app.name).font(PortholeType.ui(13.5)).foregroundStyle(PortholeStyle.text).lineLimit(1)
                        Spacer(minLength: 6)
                        if app.windows.count > 1 {
                            Button {
                                if expanded.contains(app.bundleID) { expanded.remove(app.bundleID) } else { expanded.insert(app.bundleID) }
                            } label: {
                                HStack(spacing: 4) {
                                    Text("\(app.windows.count)").font(PortholeType.ui(11.5)).foregroundStyle(PortholeStyle.muted)
                                    Image(systemName: expanded.contains(app.bundleID) ? "chevron.up" : "chevron.down")
                                        .font(PortholeType.ui(11)).foregroundStyle(PortholeStyle.muted)
                                }
                                .frame(minWidth: 44, minHeight: 32)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(expanded.contains(app.bundleID) ? "Hide windows" : "Show \(app.windows.count) windows")
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(isActive(app) ? PortholeStyle.selected : .clear, in: RoundedRectangle(cornerRadius: 11))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button { PortholeFavourites.edit { $0.add(bundleID: app.bundleID, name: app.name) } } label: {
                        Label("Add to favourites", systemImage: "star")
                    }
                }
                if expanded.contains(app.bundleID) {
                    ForEach(app.windows) { w in
                        Button { client.show(window: w.id); open(.apps) } label: {
                            Text(w.title.isEmpty ? app.name : w.title).font(PortholeType.ui(12.5))
                                .foregroundStyle(client.active == .window(w.id) ? PortholeStyle.text : PortholeStyle.soft)
                                .lineLimit(1).padding(.leading, 47).padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button { onTiles() } label: {
                HStack(spacing: 11) {
                    Image(systemName: "rectangle.split.2x2").font(PortholeType.ui(15)).frame(width: 24, height: 24)
                    Text("Tiles").font(PortholeType.ui(13.5))
                    Spacer()
                    Text("⌃⌥G").font(PortholeType.ui(11, mono: true)).foregroundStyle(PortholeStyle.muted)
                }
                .foregroundStyle(PortholeStyle.soft)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { allAppsShown = true } label: {
                HStack(spacing: 11) {
                    Image(systemName: "square.grid.2x2").font(PortholeType.ui(15)).frame(width: 24, height: 24)
                    Text("All apps").font(PortholeType.ui(13.5))
                    Spacer()
                }
                .foregroundStyle(PortholeStyle.soft)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: The order ⌃⌥↓ walks

    /// Other apps: every app with a window that isn't one of Your apps, by name, so the list holds still
    /// while ⌃⌥↓ walks it (in recent order each step moved the app it reached to the top); each app's
    /// windows in the order the Mac first listed them.
    @MainActor static func otherApps(_ client: StreamClient) -> [PortholeApps.App] {
        PortholeApps.apps(client.windows)
            .filter { app in !PortholeFavourites.apps.contains { $0.bundleID == app.bundleID } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The apps' windows in the sidebar's order: Your apps', then Other apps'.
    @MainActor static func appWindows(_ client: StreamClient) -> [WindowInfo] {
        PortholeFavourites.apps.flatMap { fav in client.windows.filter { $0.bundleID == fav.bundleID } }
            + otherApps(client).flatMap(\.windows)
    }

    /// Every window the sidebar shows, top to bottom: the sessions' iTerm windows as the sections order
    /// them, then the apps'. What ⌃⌥↓ and ⌃⌥↑ walk through, each window once.
    @MainActor static func windowOrder(_ client: StreamClient) -> [UInt32] {
        let live = Set(client.windows.map(\.id))
        let sessions = client.porthole.sessions
        let sessionWindows = (sessions.filter { $0.state == .needsYou } + sessions.filter { $0.state == .working }
                              + sessions.filter { $0.state == .done || $0.state == .idle }).compactMap(\.windowID)
        var seen = Set<UInt32>()
        return (sessionWindows + appWindows(client).map(\.id)).filter { live.contains($0) && seen.insert($0).inserted }
    }

    /// One step along `order` from what streams, wrapping round; from anything else, the first (or last).
    static func step(from active: StreamSource, in order: [UInt32], by step: Int) -> UInt32? {
        guard !order.isEmpty else { return nil }
        guard case .window(let id) = active, let i = order.firstIndex(of: id) else { return step > 0 ? order.first : order.last }
        return order[((i + step) % order.count + order.count) % order.count]
    }

    /// The row that shows window `id`: its session's, else its app's.
    @MainActor static func row(showing id: UInt32, _ client: StreamClient) -> String? {
        client.porthole.sessions.first { $0.windowID == id }?.id ?? client.windows.first { $0.id == id }?.bundleID
    }

    private func isActive(_ app: PortholeApps.App) -> Bool {
        guard pick == .apps, case .window(let id) = client.active else { return false }
        return app.windows.contains { $0.id == id }
    }

    static func stateWords(_ s: ClaudeSession) -> String {
        switch s.state {
        case .needsYou: return "needs you" + (PortholeStyle.waited(s.since).map { ", waiting \($0)" } ?? "")
        case .working: return "working"
        case .done: return "done"
        case .idle: return "idle"
        }
    }
}

struct PortholeStateDot: View {
    let state: ClaudeSession.State
    var body: some View {
        switch state {
        case .needsYou:
            Circle().fill(PortholeStyle.brass).frame(width: 9, height: 9)
        case .working:
            Circle().trim(from: 0, to: 0.72).stroke(PortholeStyle.blue, lineWidth: 2).frame(width: 9, height: 9)
        case .done:
            Circle().stroke(PortholeStyle.soft, lineWidth: 2).frame(width: 9, height: 9)
        case .idle:
            Circle().stroke(PortholeStyle.muted.opacity(0.6), lineWidth: 2).frame(width: 9, height: 9)
        }
    }
}

/// Every app installed on the Mac (Porthole's list), searchable; a tap opens it and streams its window.
struct PortholeAllApps: View {
    @ObservedObject var client: StreamClient
    @Binding var shown: Bool
    @State private var query = ""
    @AppStorage(PortholeFavourites.storageKey) private var favourites: Data?
    var body: some View {
        NavigationStack {
            List(client.apps.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { app in
                Button { client.launch(bundleID: app.bundleID); shown = false } label: {
                    HStack(spacing: 12) {
                        if let icon = client.icons[app.bundleID] { Image(uiImage: icon).resizable().frame(width: 26, height: 26) }
                        Text(app.name)
                        Spacer()
                        if PortholeFavourites.list.contains(app.bundleID) {
                            Image(systemName: "star.fill").font(PortholeType.ui(12)).foregroundStyle(PortholeStyle.brass)
                        }
                    }
                }
                .contextMenu {
                    if PortholeFavourites.list.contains(app.bundleID) {
                        Button(role: .destructive) { PortholeFavourites.edit { $0.remove(app.bundleID) } } label: {
                            Label("Remove from favourites", systemImage: "star.slash")
                        }
                    } else {
                        Button { PortholeFavourites.edit { $0.add(bundleID: app.bundleID, name: app.name) } } label: {
                            Label("Add to favourites", systemImage: "star")
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Find an app")
            .navigationTitle("All apps")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { shown = false } } }
        }
        .preferredColorScheme(.dark)
    }
}

enum PortholeBrowserIDs {
    static let chrome = "com.google.Chrome"
    /// "https://docs.google.com/presentation/d/…" → "docs.google.com".
    static func host(_ url: String) -> String { URL(string: url)?.host ?? url }
}

/// Sessions as Window | Text (docs/agent-view-plan.md), in the sidebar under the agent view: over the
/// picture it covered the top bar's Settings button. ⌃⌥T does the same.
struct PortholeTextSwitch: View {
    enum Mode { case window, text, textWithAgent }
    let mode: Mode
    let set: (Mode) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Text("Sessions as").font(PortholeType.ui(12)).foregroundStyle(PortholeStyle.muted).padding(.horizontal, 8)
            Spacer(minLength: 4)
            ForEach([(Mode.window, "Window"), (.text, "Text"), (.textWithAgent, "+ Agents")], id: \.1) { m, label in
                Button { set(m) } label: {
                    Text(label).font(PortholeType.ui(12, .medium))
                        .padding(.horizontal, 9).frame(height: 26)
                        .background(mode == m ? PortholeStyle.field : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(mode == m ? PortholeStyle.text : PortholeStyle.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(PortholeStyle.field.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PortholeStyle.line))
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Show sessions as their windows, as text, or as text with the agent view beside, Control Option T")
    }
}

/// Porthole's own type: the system font, or, with the Pro terminal theme (Jon, 21 Oct: "a TUI style mode"),
/// his terminal's own, Hack, so Porthole itself reads as a terminal UI.
@MainActor
enum PortholeType {
    static let themeKey = "Porthole.tuiTheme"
    static var tui: Bool { UserDefaults.standard.bool(forKey: themeKey) && PortholePro.shared.unlocked }

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular, mono: Bool = false) -> Font {
        guard tui else { return .system(size: size, weight: weight, design: mono ? .monospaced : .default) }
        let bold = weight == .semibold || weight == .bold || weight == .heavy
        return .custom(bold ? "HackNFM-Bold" : "HackNFM-Regular", size: size * 0.94)
    }
}

/// Text colours: Dark | Light, under the sessions' switch. Dark unless picked (Jon, 21 Oct: "the Claude text
/// colours are in day mode, how can we swap between these").
struct PortholeColoursSwitch: View {
    let colours: String
    let set: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Text("Text colours").font(.system(size: 12)).foregroundStyle(PortholeStyle.muted).padding(.horizontal, 8)
            Spacer(minLength: 4)
            ForEach([("dark", "Dark"), ("light", "Light")], id: \.0) { value, label in
                Button { set(value) } label: {
                    Text(label).font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(colours == value ? PortholeStyle.field : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(colours == value ? PortholeStyle.text : PortholeStyle.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(PortholeStyle.field.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PortholeStyle.line))
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Text colours, dark or light")
    }
}
