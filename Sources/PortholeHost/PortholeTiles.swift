import AppKit
import ScreenCaptureKit
import StreamProtocol

/// Porthole (docs/porthole-plan.md, Tiles): two Mac windows side by side, or four in a 2×2 grid, on a
/// virtual display the size of the device's panel, streamed as one picture (`StreamSource.tiles`). Jon
/// never uses the Mac and the device at the same time, so the windows may move; each goes back to where
/// it was when tiles stop (another source, the last device leaving, the host quitting).
///
/// Separate from Porthole's own stage (VirtualStage, one window): its own display, with its own serial
/// number so System Settings keeps the two apart.
@MainActor
final class PortholeTiles {
    struct Prepared {
        let filter: SCContentFilter
        /// The tiles' area in the display's own points (below its menu bar): what is captured.
        let sourceRect: CGRect
        let describe: String
    }

    enum Failure: Error, CustomStringConvertible {
        case permissions, displayCreate(Error), neverOnline, notListed, noWindows
        var description: String {
            switch self {
            case .permissions: return "tiles need Accessibility and Screen Recording"
            case .displayCreate(let e): return "the tiles' display couldn't be created (\(e))"
            case .neverOnline: return "the tiles' display never came up"
            case .notListed: return "ScreenCaptureKit didn't list the tiles' display"
            case .noWindows: return "none of the windows could be moved"
            }
        }
    }

    private let sizer: WindowSizer
    private var display: VirtualDisplay?
    private var scDisplay: SCDisplay?
    private var placements: [WindowSizer.Placement] = []
    /// The tiles' area in global points (where the device's input lands).
    private var usable: CGRect = .zero
    private var builtFor: CGSize = .zero

    static let serialNum: UInt32 = 2
    /// Room for the menu bar macOS draws on the display, above the tiles.
    static let menuAllowance: CGFloat = 40

    init(sizer: WindowSizer) { self.sizer = sizer }

    var isActive: Bool { display != nil }
    var rectOnScreen: CGRect? { display == nil ? nil : usable }

    /// Puts `windows` (two or four used; one alone fills the display) on a display the panel's size and
    /// returns what to capture.
    func prepare(windows: [SCWindow], panel: CGSize, refreshHz: Int, own: SCRunningApplication?) async throws -> Prepared {
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else { throw Failure.permissions }
        let size = VirtualStage.clamp(CGSize(width: panel.width.rounded(), height: panel.height.rounded()))
        try await ensureDisplay(size, refreshHz: refreshHz)
        guard let d = display, let scDisplay else { throw Failure.neverOnline }
        let bounds = CGDisplayBounds(d.displayID)
        usable = VirtualStage.usableArea(of: d.displayID) ?? bounds.divided(atDistance: Self.menuAllowance, from: .minYEdge).remainder

        // Windows that left the layout go home; the ones that stay keep their way home.
        let wanted = Set(windows.map(\.windowID))
        for p in placements where !wanted.contains(p.windowID) { Self.goHome(p) }
        placements.removeAll { !wanted.contains($0.windowID) }

        let frames = PortholeWire.tileFrames(count: windows.count, in: usable.size, gap: 4)
        var placed = 0
        for (i, window) in windows.prefix(PortholeWire.maxTiles).enumerated() where i < frames.count {
            var p = placements.first { $0.windowID == window.windowID }
            if p == nil, let fresh = sizer.placement(for: window) {
                // A window found on this display (left by an earlier run) gets a home on the main display.
                p = fresh.originalFrame.intersects(bounds) ? fresh.homed(at: WindowSizer.homeFrame(size: fresh.originalFrame.size)) : fresh
                placements.append(p!)
            }
            guard let p else { continue }
            if WindowSizer.isFullScreen(p.element) {
                // A window in its own full-screen Space can't be moved: out of full screen first.
                _ = WindowSizer.perform(.fullScreen, element: p.element)
                let deadline = Date().addingTimeInterval(2)
                while WindowSizer.isFullScreen(p.element), Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .milliseconds(400))
            }
            let frame = frames[i].offsetBy(dx: usable.minX, dy: usable.minY)
            if sizer.move(p, to: frame) == .success { placed += 1 }
        }
        guard placed > 0 else { release(); throw Failure.noWindows }
        // Let the apps commit their new frames before the first frame is captured.
        try? await Task.sleep(for: .milliseconds(250))

        let filter = own.map { SCContentFilter(display: scDisplay, excludingApplications: [$0], exceptingWindows: []) }
            ?? SCContentFilter(display: scDisplay, excludingWindows: [])
        let source = CGRect(x: usable.minX - bounds.minX, y: usable.minY - bounds.minY, width: usable.width, height: usable.height)
        let names = windows.compactMap { $0.owningApplication?.applicationName }.joined(separator: ", ")
        return Prepared(filter: filter, sourceRect: source, describe: "\(windows.count) tiles (\(names)) on virtual display \(d.displayID)")
    }

    /// Every window back where it was, and the display gone. An app that snaps its frame (iTerm2 keeps
    /// whole character cells, and the tiles' display is @2× where the main one may not be) can land a
    /// little off on the way back: two more passes put those right.
    func release() {
        let homes = placements
        for p in homes { Self.goHome(p) }
        placements = []
        display?.destroy()
        display = nil
        scDisplay = nil
        builtFor = .zero
        guard !homes.isEmpty else { return }
        for delay in [0.5, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                for p in homes where Self.off(p) { Self.goHome(p) }
            }
        }
    }

    /// A window's way home: its size first, while it still has the tiles' display to grow or shrink in,
    /// then its place, then both again. Porthole's order (place, size, place) lands a tall tile at the
    /// bottom of a shorter screen first, where macOS pushes it and iTerm2 keeps the stretch (found 17 Oct:
    /// a window by the screen's bottom came back 60 pt taller).
    private static func goHome(_ p: WindowSizer.Placement) {
        var size = p.originalFrame.size, origin = p.originalFrame.origin
        guard let s = AXValueCreate(.cgSize, &size), let o = AXValueCreate(.cgPoint, &origin) else { return }
        for _ in 0..<2 {
            AXUIElementSetAttributeValue(p.element, kAXSizeAttribute as CFString, s)
            AXUIElementSetAttributeValue(p.element, kAXPositionAttribute as CFString, o)
        }
        AXUIElementSetAttributeValue(p.element, kAXSizeAttribute as CFString, s)
    }

    /// Whether a window is more than 2 pt from its way home.
    private static func off(_ p: WindowSizer.Placement) -> Bool {
        guard let live = WindowSizer.liveBounds(of: p.windowID) else { return false }
        let o = p.originalFrame
        return abs(live.minX - o.minX) > 2 || abs(live.minY - o.minY) > 2 || abs(live.width - o.width) > 2 || abs(live.height - o.height) > 2
    }

    private func ensureDisplay(_ size: CGSize, refreshHz: Int) async throws {
        if let d = display, d.isAlive, scDisplay != nil, builtFor == size { return }
        // A new size: the windows go home first, so none is left on a display that disappears.
        let keep = placements
        release()
        placements = keep.map { $0 }
        let d: VirtualDisplay
        do {
            d = try VirtualDisplay(name: "Porthole tiles", widthPt: Int(size.width), heightPt: Int(size.height + Self.menuAllowance), scale: 2,
                                   refreshHz: Double(refreshHz), vendorID: VirtualStage.vendorID, productID: VirtualStage.productID,
                                   serialNum: Self.serialNum)
        } catch {
            throw Failure.displayCreate(error)
        }
        display = d
        builtFor = size
        guard await d.waitUntilOnline(timeout: 3) || d.bounds.width > 0 else { release(); throw Failure.neverOnline }
        // AppKit learns of the screen through the run loop, ScreenCaptureKit a little after.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let c = await WindowCatalog.shareableContent(excludingDesktopWindows: true, onScreenWindowsOnly: true, timeout: 1),
               let found = c.displays.first(where: { $0.displayID == d.displayID }) {
                scDisplay = found
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard scDisplay != nil else { release(); throw Failure.notListed }
        let menuDeadline = Date().addingTimeInterval(1)
        while VirtualStage.usableArea(of: d.displayID) == nil, Date() < menuDeadline { try? await Task.sleep(for: .milliseconds(50)) }
        print("Porthole: tiles display \(Int(size.width))×\(Int(size.height)) pt @2× id \(d.displayID)")
    }
}
