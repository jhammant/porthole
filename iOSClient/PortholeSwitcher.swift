import SwiftUI
import StreamProtocol

/// Porthole (docs/porthole-plan.md): the quick switcher (⌃⌥Space). Type a few letters of a Claude Code
/// session, a Mac window or an app; ↑ ↓ move, Return opens, Esc closes. Sessions that need you come first.
struct PortholeSwitcher: View {
    @ObservedObject var client: StreamClient
    @Binding var shown: Bool
    let open: (PortholePick) -> Void
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    struct Hit: Identifiable {
        enum Target { case session(String), window(UInt32), app(String), tab(BrowserTab, BrowserWindow), desktop(UInt32?) }
        let id: String
        let group: String
        let title: String
        let detail: String
        let target: Target
        let needsYou: Bool
    }

    var body: some View {
        let hits = Self.hits(query, client: client)
        ZStack(alignment: .top) {
            Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { shown = false }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(PortholeStyle.muted)
                    TextField("Find a session, window or app", text: $query)
                        .focused($focused)
                        .font(.system(size: 16))
                        .foregroundStyle(PortholeStyle.text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { choose(hits) }
                        .onKeyPress(.downArrow) { selected = min(selected + 1, max(hits.count - 1, 0)); return .handled }
                        .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
                        .onKeyPress(.escape) { shown = false; return .handled }
                    Text("⌃⌥Space").font(.system(size: 11, design: .monospaced)).foregroundStyle(PortholeStyle.muted)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .overlay(alignment: .bottom) { Rectangle().fill(PortholeStyle.line).frame(height: 1) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(hits.enumerated()), id: \.element.id) { i, hit in
                            if i == 0 || hits[i - 1].group != hit.group {
                                Text(hit.group.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(1.2)
                                    .foregroundStyle(PortholeStyle.label).padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 3)
                            }
                            Button { selected = i; choose(hits) } label: {
                                HStack(spacing: 12) {
                                    Circle().fill(hit.needsYou ? PortholeStyle.brass : PortholeStyle.muted.opacity(0.5)).frame(width: 8, height: 8)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(hit.title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(PortholeStyle.text).lineLimit(1)
                                        Text(hit.detail).font(.system(size: 11.5)).foregroundStyle(PortholeStyle.muted).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    if i == selected {
                                        Text("return").font(.system(size: 11, design: .monospaced)).foregroundStyle(PortholeStyle.brass)
                                    }
                                }
                                .padding(10)
                                .background(i == selected ? PortholeStyle.selected : .clear, in: RoundedRectangle(cornerRadius: 11))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if hits.isEmpty {
                            Text("Nothing matches.").font(.system(size: 13)).foregroundStyle(PortholeStyle.muted).padding(14)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 420)
                HStack(spacing: 16) {
                    Text("↑↓ move"); Text("return open"); Text("⌃⌥J next needing you")
                }
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(PortholeStyle.muted)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(PortholeStyle.line).frame(height: 1) }
            }
            .frame(maxWidth: 440)
            .background(Color(red: 0x12 / 255, green: 0x1B / 255, blue: 0x24 / 255), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(red: 0x26 / 255, green: 0x34 / 255, blue: 0x3F / 255)))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
            .padding(.top, 40).padding(.horizontal, 16)
        }
        .onAppear {
            focused = true; selected = 0
            #if DEBUG
            if let q = UserDefaults.standard.string(forKey: "PortholeSwitcher") { query = q }
            #endif
        }
        .onChange(of: query) { _, _ in selected = 0 }
    }

    private func choose(_ hits: [Hit]) {
        guard hits.indices.contains(selected) else { return }
        shown = false
        switch hits[selected].target {
        case .session(let id): open(.session(id))
        case .window(let id): client.show(window: id); open(.apps)
        case .app(let bundleID): client.launch(bundleID: bundleID); open(.apps)
        case .tab(let tab, let window): client.open(tab: tab, in: window); open(.apps)
        case .desktop(let display):
            if let display, display != client.desktopDisplay { client.pickDisplay(display) } else { client.select(.desktop) }
            open(.apps)
        }
    }

    /// Matches for `query`: the Desktop, sessions (needs you first), then open windows, then installed apps;
    /// with no query, the sessions that need you and the most recent windows.
    static func hits(_ query: String, client: StreamClient) -> [Hit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        func match(_ s: String...) -> Bool { q.isEmpty || s.contains { $0.localizedCaseInsensitiveContains(q) } }
        var hits: [Hit] = []
        // "des…", "scr…", a screen's name: the Desktop (⌃⌥D) first, so Return opens it; one hit for each screen
        // when there are two or more. Three letters at least, so a session's first letter still leads.
        let word = q.lowercased()
        let named = word.count >= 3 && ["desktop", "screen"].contains { $0.hasPrefix(word) }
        let screens = client.displays.count > 1 ? client.displays : []
        if screens.isEmpty, named {
            hits.append(Hit(id: "d:", group: "Mac", title: "Desktop", detail: "The whole Mac screen · ⌃⌥D", target: .desktop(nil), needsYou: false))
        }
        for d in screens where named || (word.count >= 2 && d.name.localizedCaseInsensitiveContains(q)) {
            hits.append(Hit(id: "d:\(d.id)", group: "Mac", title: "Desktop · \(d.name)", detail: d.main ? "The main screen · ⌃⌥D" : "Another screen",
                            target: .desktop(d.id), needsYou: false))
        }
        for s in client.porthole.sessions where match(s.title, s.portal, s.folder) && (!q.isEmpty || s.state == .needsYou) {
            let detail = s.state == .needsYou ? "\(s.portal), needs you" + (PortholeStyle.waited(s.since).map { " for \($0)" } ?? "") : s.portal
            hits.append(Hit(id: "s:" + s.id, group: "Claude Code", title: s.title, detail: detail, target: .session(s.id), needsYou: s.state == .needsYou))
        }
        let windows = client.recentWindows.filter { match($0.title, $0.appName) }.prefix(q.isEmpty ? 6 : 12)
        for w in windows {
            hits.append(Hit(id: "w:\(w.id)", group: "Windows", title: w.title.isEmpty ? w.appName : w.title, detail: w.appName,
                            target: .window(w.id), needsYou: false))
        }
        if !q.isEmpty, let tabs = client.porthole.browserTabs {
            var n = 0
            for window in tabs.windows {
                for tab in window.tabs where match(tab.title, tab.url) && n < 12 {
                    n += 1
                    hits.append(Hit(id: "t:\(tab.id)", group: "Chrome tabs", title: tab.title, detail: PortholeBrowserIDs.host(tab.url),
                                    target: .tab(tab, window), needsYou: false))
                }
            }
        }
        if !q.isEmpty {
            let open = Set(client.windows.map(\.bundleID))
            for a in client.apps where !open.contains(a.bundleID) && match(a.name) {
                hits.append(Hit(id: "a:" + a.bundleID, group: "Apps", title: a.name, detail: "Open on the Mac", target: .app(a.bundleID), needsYou: false))
                if hits.count > 40 { break }
            }
        }
        return hits
    }
}
