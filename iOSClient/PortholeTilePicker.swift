import SwiftUI
import StreamProtocol

/// Porthole (docs/porthole-plan.md, Tiles): two Mac windows side by side or four in a 2×2 grid. The Mac
/// lays them out on a display the size of this panel and streams it as one picture (`.tiles`). The
/// picker starts with the most recent windows chosen; tap to change, Show to stream.
struct PortholeTilePicker: View {
    @ObservedObject var client: StreamClient
    @Binding var shown: Bool
    let show: ([UInt32]) -> Void
    @State private var count = 2
    @State private var chosen: [UInt32] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Layout", selection: $count) {
                    Text("Two, side by side").tag(2)
                    Text("Four, 2×2").tag(4)
                }
                .pickerStyle(.segmented)
                .padding(16)
                List(client.recentWindows) { w in
                    Button { toggle(w.id) } label: {
                        HStack(spacing: 12) {
                            if let icon = client.icons[w.bundleID] { Image(uiImage: icon).resizable().frame(width: 26, height: 26) }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(w.title.isEmpty ? w.appName : w.title).lineLimit(1)
                                Text(w.appName).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let i = chosen.firstIndex(of: w.id) {
                                Text("\(i + 1)").font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .frame(width: 26, height: 26)
                                    .background(PortholeStyle.brass, in: Circle())
                                    .foregroundStyle(Color.black)
                            }
                        }
                    }
                    .accessibilityAddTraits(chosen.contains(w.id) ? .isSelected : [])
                }
            }
            .navigationTitle("Tiles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { shown = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Show") { show(chosen); shown = false }.disabled(chosen.count < 2)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { chosen = Array(client.recentWindows.prefix(count).map(\.id)) }
        .onChange(of: count) { _, n in
            if chosen.count > n { chosen = Array(chosen.prefix(n)) }
            for w in client.recentWindows where chosen.count < n && !chosen.contains(w.id) { chosen.append(w.id) }
        }
    }

    private func toggle(_ id: UInt32) {
        if let i = chosen.firstIndex(of: id) { chosen.remove(at: i) } else if chosen.count < count { chosen.append(id) }
    }

    /// ⌃⌥G: one window → two tiles → four tiles → back to the first window. Extra tiles come from the
    /// most recent windows (the host's list is front to back).
    static func next(after active: StreamSource, windows: [WindowInfo]) -> StreamSource? {
        let recent = windows.map(\.id)
        func fill(_ ids: [UInt32], to n: Int) -> [UInt32] {
            var out = ids
            for id in recent where out.count < n && !out.contains(id) { out.append(id) }
            return out
        }
        switch active {
        case .window(let id):
            let two = fill([id], to: 2)
            return two.count == 2 ? .tiles(two) : nil
        case .tiles(let ids) where ids.count <= 2:
            let four = fill(ids, to: 4)
            return four.count > 2 ? .tiles(four) : .window(ids[0])
        case .tiles(let ids):
            return ids.first.map { .window($0) }
        case .desktop, .none:
            let two = fill([], to: 2)
            return two.count == 2 ? .tiles(two) : nil
        }
    }
}
