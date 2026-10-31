import SwiftUI
import UIKit

/// Porthole (31 Oct, "Can you put debug recording in the app maybe?"): while it is on (the sidebar's Debug
/// Recording), what the app sees and does, one line each, kept on this device: every touch and the view that
/// takes it, the layout as it changes (size, the Duo's pose, the arrangement), the keyboard's and the
/// buttons' doings. Copy Debug Log puts it on the clipboard, which reaches the Mac (Porthole's shared
/// clipboard or Universal Clipboard). Nothing is recorded while it is off, and nothing leaves the device but
/// by that copy. No words typed are kept: keys are noted by what they did, not what they were.
@MainActor final class PortholeDebugRecorder: ObservableObject {
    static let shared = PortholeDebugRecorder()
    private static let key = "Porthole.debugRecording"
    private static let keep = 4000

    @Published var on: Bool {
        didSet {
            UserDefaults.standard.set(on, forKey: Self.key)
            if on { lines = []; note("recording on: \(Self.device)"); watchWindows() }
        }
    }
    @Published private(set) var count = 0
    private var lines: [String] = []
    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {
        on = UserDefaults.standard.bool(forKey: Self.key)
        if on { DispatchQueue.main.async { self.watchWindows() } }
    }

    /// One line, stamped, while recording; nothing at all otherwise (the words are built only when on).
    func note(_ line: @autoclosure () -> String) {
        guard on else { return }
        lines.append(clock.string(from: Date()) + " " + line())
        if lines.count > Self.keep { lines.removeFirst(lines.count - Self.keep) }
        count = lines.count
    }

    /// The log as copied: the device, then every line.
    var text: String { (["Porthole debug log", Self.device] + lines).joined(separator: "\n") }

    func copy() {
        note("log copied (\(lines.count) lines)")
        UIPasteboard.general.string = text
    }

    static var device: String {
        var info = utsname()
        uname(&info)
        let model = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let screen = UIScreen.main.bounds.size
        return "\(model), iOS \(UIDevice.current.systemVersion), Porthole build \(build), screen \(Int(screen.width))×\(Int(screen.height)) pt"
    }

    // MARK: Touches

    /// A touch watcher on every window of the app, added once each.
    func watchWindows() {
        guard on else { return }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows where !(window.gestureRecognizers ?? []).contains(where: { $0 is TouchRecorder }) {
                window.addGestureRecognizer(TouchRecorder())
            }
        }
    }

    /// "InputOverlayView < PlatformViewHost < … " for the view a point's touch goes to, and its first parents.
    static func chain(_ view: UIView?) -> String {
        var names: [String] = []
        var v = view
        while let current = v, names.count < 4 {
            var name = String(describing: type(of: current))
            if let generic = name.firstIndex(of: "<") { name = String(name[..<generic]) }
            if let label = current.accessibilityLabel, !label.isEmpty { name += "[\(label.prefix(30))]" }
            names.append(name)
            v = current.superview
        }
        return names.joined(separator: " < ")
    }
}

/// Sees every touch of its window and takes none: never recognizes, cancels nothing, delays nothing, runs
/// beside every other recognizer (as StrokeObserver does).
private final class TouchRecorder: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private var began: [ObjectIdentifier: (point: CGPoint, time: TimeInterval)] = [:]

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let window = view as? UIWindow else { return }
        for touch in touches {
            let p = touch.location(in: window)
            began[ObjectIdentifier(touch)] = (p, touch.timestamp)
            let hit = window.hitTest(p, with: event)
            MainActor.assumeIsolated {
                PortholeDebugRecorder.shared.note(String(format: "touch down %.0f,%.0f in %.0f×%.0f → ", p.x, p.y, window.bounds.width, window.bounds.height)
                                                  + PortholeDebugRecorder.chain(hit))
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, "up") }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, "cancelled") }

    private func finish(_ touches: Set<UITouch>, _ how: String) {
        guard let window = view as? UIWindow else { return }
        for touch in touches {
            guard let start = began.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            let p = touch.location(in: window)
            let moved = hypot(p.x - start.point.x, p.y - start.point.y)
            MainActor.assumeIsolated {
                PortholeDebugRecorder.shared.note(String(format: "touch %@ after %.2f s, moved %.0f pt", how, touch.timestamp - start.time, moved))
            }
        }
    }
}
