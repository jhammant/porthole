import Foundation

/// The iPhone Duo's two ways to show the Mac (Jon, 21 Oct 2026: "When half folded the duo should be a mini
/// laptop style. When flat unfolded it should be a whole screen. Need this in settings as well"):
/// - the laptop: the picture above the fold, a Mac keyboard below it (PortholeLaptopKeyboard), as a tiny
///   folded laptop;
/// - the whole screen: the picture over all of the display under the bar, as sideways and on an iPad.
/// Held upright, half-folded is the laptop and open flat the whole screen, unless This iPhone's rows in
/// the Settings panel say otherwise. Sideways, open flat the sidebar is the usual one (dragged, hidden),
/// so the Mac can have the whole display; only the book pose's fold divides it.
/// Pure (Foundation, DuoPosture's poses), for Tests/checks/duo-mode.
enum PortholeDuoMode: String, CaseIterable, Identifiable {
    case laptop, wholeScreen

    var id: String { rawValue }

    /// The Settings panel's choices, kept across launches.
    static let halfFoldedKey = "Porthole.duoHalfFolded"
    static let flatKey = "Porthole.duoFlat"
    static let halfFoldedDefault: PortholeDuoMode = .laptop
    static let flatDefault: PortholeDuoMode = .wholeScreen

    var title: String { self == .laptop ? "Laptop" : "Whole Screen" }

    /// What the inner display shows held upright in `pose`; nil in every other pose (sideways, the cover,
    /// a device without a hinge), which keep their own layouts.
    static func upright(_ pose: DuoPosture.Pose, halfFolded: PortholeDuoMode, flat: PortholeDuoMode) -> PortholeDuoMode? {
        switch pose {
        case .laptop: return halfFolded
        case .flatPortrait: return flat
        default: return nil
        }
    }

    /// Whether the stream screen draws the whole screen (StreamScreen's sideways layout) in `pose`.
    static func wholeScreen(_ pose: DuoPosture.Pose, halfFolded: PortholeDuoMode, flat: PortholeDuoMode) -> Bool {
        upright(pose, halfFolded: halfFolded, flat: flat) == .wholeScreen
    }

    /// Sideways, whether the fold is the sidebar's divider (each side a phone's width): half-folded as a
    /// book, yes; open flat, no.
    static func foldDivides(_ pose: DuoPosture.Pose) -> Bool { pose == .book }
}
