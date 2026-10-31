import SwiftUI
import UIKit
import StreamProtocol

/// Porthole (30 Oct, "CTRL down arrow or up arrow. Same as the mac options"): the Mac's App Exposé (⌃↓, the
/// windows of the app on screen) and Mission Control (⌃↑, every window, app by app), as the windows'
/// pictures to pick from. ← → ↑ ↓ move, Return opens, Esc or the same key again closes; a tap opens.
struct PortholeExpose: View {
    enum Mode: Equatable { case app(String), all }
    enum Move { case left, right, up, down }

    @ObservedObject var client: StreamClient
    @ObservedObject var model: PortholeExposeModel

    static let spacing: CGFloat = 14
    static let minCard: CGFloat = 200

    var body: some View {
        if let mode = model.mode {
            let list = Self.windows(mode, in: client.windows)
            GeometryReader { geo in
                let columns = Self.columns(for: geo.size.width)
                ZStack(alignment: .top) {
                    Color.black.opacity(0.9).ignoresSafeArea().onTapGesture { model.close() }
                    VStack(alignment: .leading, spacing: 12) {
                        header(mode, count: list.count)
                        if list.isEmpty {
                            Text("No windows").font(PortholeType.ui(14)).foregroundStyle(PortholeStyle.muted)
                                .frame(maxWidth: .infinity).padding(.top, 40)
                        } else {
                            ScrollViewReader { scroller in
                                ScrollView {
                                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: columns),
                                              spacing: Self.spacing) {
                                        ForEach(list) { w in card(w, mode: mode).id(w.id) }
                                    }
                                    .padding(.bottom, 20)
                                }
                                .onChange(of: model.selected) { _, id in
                                    if let id { withAnimation(.easeOut(duration: 0.12)) { scroller.scrollTo(id) } }
                                }
                            }
                        }
                    }
                    .padding(Self.spacing + 6)
                }
                .onAppear { model.laidOut(list.map(\.id), columns: columns) }
                .onChange(of: list.map(\.id)) { _, ids in model.laidOut(ids, columns: columns) }
                .onChange(of: columns) { _, n in model.laidOut(list.map(\.id), columns: n) }
            }
            .transition(.opacity)
        }
    }

    private func header(_ mode: Mode, count: Int) -> some View {
        let title: String
        switch mode {
        case .app(let bundleID):
            let name = client.windows.first { $0.bundleID == bundleID }?.appName ?? "This app"
            title = "\(name) · \(count == 1 ? "1 window" : "\(count) windows")"
        case .all:
            title = "Every window · \(count)"
        }
        return HStack {
            Text(title).font(PortholeType.ui(15, .semibold)).foregroundStyle(PortholeStyle.text)
            Spacer()
            Text(mode == .all ? "⌃↑ Mission Control" : "⌃↓ App Exposé")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(PortholeStyle.muted)
        }
    }

    private func card(_ w: WindowInfo, mode: Mode) -> some View {
        let selected = model.selected == w.id
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button { model.pick(w.id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Color.white.opacity(0.05)
                    if let image = client.thumbnails[w.id] {
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "macwindow").font(.system(size: 28)).foregroundStyle(PortholeStyle.muted)
                    }
                }
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(shape)
                .overlay(shape.strokeBorder(selected ? Palette.accent : Color.white.opacity(0.12), lineWidth: selected ? 3 : 1))
                HStack(spacing: 6) {
                    if mode == .all, let icon = client.icons[w.bundleID] {
                        Image(uiImage: icon).resizable().frame(width: 16, height: 16)
                    }
                    Text(w.title.isEmpty ? w.appName : w.title)
                        .font(PortholeType.ui(12, selected ? .semibold : .regular))
                        .foregroundStyle(selected ? PortholeStyle.text : PortholeStyle.muted)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(w.appName) window: \(w.title)")
    }

    // MARK: The rules (Tests/checks/expose)

    /// The windows shown: the app's, front to back, or every window grouped by app, the most recent app first.
    static func windows(_ mode: Mode, in all: [WindowInfo]) -> [WindowInfo] {
        switch mode {
        case .app(let bundleID): return all.filter { $0.bundleID == bundleID }
        case .all: return PortholeApps.apps(all).flatMap(\.windows)
        }
    }

    static func columns(for width: CGFloat) -> Int {
        max(1, min(5, Int((width - 2 * (spacing + 6) + spacing) / (minCard + spacing))))
    }

    /// The card an arrow key moves to in a grid of `count` cards, `columns` wide: left and right run on
    /// through the rows, up and down stay put at the top and bottom.
    static func step(_ index: Int, _ move: Move, count: Int, columns: Int) -> Int {
        guard count > 0 else { return 0 }
        let i = min(max(index, 0), count - 1), n = max(columns, 1)
        switch move {
        case .left: return max(i - 1, 0)
        case .right: return min(i + 1, count - 1)
        case .up: return i - n >= 0 ? i - n : i
        case .down: return i + n < count ? i + n : (i / n < (count - 1) / n ? count - 1 : i)
        }
    }
}

/// What the exposé shows and has picked, held by the shell; while it is up it takes the keys first
/// (`PortholeHotKeys.modal`), before the stream or a session's text would send them to the Mac.
@MainActor final class PortholeExposeModel: ObservableObject {
    @Published private(set) var mode: PortholeExpose.Mode?
    @Published var selected: UInt32?
    private var ids: [UInt32] = []
    private var columns = 1
    /// The shell's way to a window (a session's row for a session's iTerm window).
    var choose: (UInt32) -> Void = { _ in }

    func show(_ mode: PortholeExpose.Mode, windows: [WindowInfo], current: UInt32?) {
        ids = PortholeExpose.windows(mode, in: windows).map(\.id)
        selected = ids.contains(where: { $0 == current }) ? current : ids.first
        withAnimation(.easeOut(duration: 0.15)) { self.mode = mode }
        PortholeHotKeys.modal = { [weak self] key, down in self?.key(key, down: down) ?? false }
    }

    func close() {
        withAnimation(.easeOut(duration: 0.15)) { mode = nil }
        PortholeHotKeys.modal = nil
    }

    func pick(_ id: UInt32) {
        close()
        choose(id)
    }

    func laidOut(_ ids: [UInt32], columns: Int) {
        self.ids = ids
        self.columns = columns
        if let s = selected, ids.contains(s) { return }
        selected = ids.first
    }

    /// A key while the exposé is up: every plain key is its own (nothing reaches the Mac meanwhile); a key
    /// with ⌃, ⌥ or ⌘ passes, so Porthole's hot keys, ⌃↓ and ⌃↑ among them, still close it or switch.
    func key(_ key: UIKey, down: Bool) -> Bool {
        guard key.modifierFlags.intersection([.control, .alternate, .command]).isEmpty else { return false }
        if down { press(key.keyCode) }
        return true
    }

    /// The arrows move, Return or Space opens, Esc closes; any other key does nothing.
    func press(_ code: UIKeyboardHIDUsage) {
        let move: PortholeExpose.Move
        switch code {
        case .keyboardEscape: close(); return
        case .keyboardReturnOrEnter, .keypadEnter, .keyboardSpacebar: if let selected { pick(selected) }; return
        case .keyboardLeftArrow: move = .left
        case .keyboardRightArrow: move = .right
        case .keyboardUpArrow: move = .up
        case .keyboardDownArrow: move = .down
        default: return
        }
        guard !ids.isEmpty else { return }
        let index = selected.flatMap { ids.firstIndex(of: $0) } ?? 0
        selected = ids[PortholeExpose.step(index, move, count: ids.count, columns: columns)]
    }
}
