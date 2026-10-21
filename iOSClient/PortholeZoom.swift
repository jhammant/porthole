import CoreGraphics

/// Pinch to zoom the Desktop (Jon, 20 Oct 2026: "multitouch zoom only when showing the full screen").
/// The device draws part of the Desktop larger; the host streams the same picture. Pure, so the picture
/// (StreamScreen: `scaleEffect` from the top leading corner, then `offset`) and the touches
/// (InputOverlayView's `videoRect`) share one transform: a point p of the panel is drawn at
/// p × scale + offset. Never smaller than the panel and never off its edges. Checked with swiftc
/// (Tests/checks/zoom).
struct PortholeZoom: Equatable {
    var scale: CGFloat = 1
    var offset: CGSize = .zero

    static let none = PortholeZoom()
    static let maxScale: CGFloat = 5
    /// Unzoomed, a pinch zooms once the fingers' spread has changed by this fraction, so a two-finger
    /// scroll whose fingers drift apart a little still scrolls. Zoomed, two fingers are the zoom's.
    static let engageRatio: CGFloat = 0.08

    var isZoomed: Bool { scale > 1.001 }

    /// `rect`, in the panel's points, where it is drawn.
    func apply(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * scale + offset.width, y: rect.minY * scale + offset.height,
               width: rect.width * scale, height: rect.height * scale)
    }

    /// The zoom a pinch makes: begun at `start` with the fingers' centre at `from`, now at `scale`
    /// times the start's with the centre at `to`. The point under the fingers stays under them, so
    /// moving both fingers pans. Clamped to the panel (`bounds`).
    static func pinched(from start: PortholeZoom, at from: CGPoint, scale: CGFloat, to: CGPoint, in bounds: CGSize) -> PortholeZoom {
        let s = min(max(start.scale * scale, 1), maxScale)
        let q = CGPoint(x: (from.x - start.offset.width) / start.scale, y: (from.y - start.offset.height) / start.scale)
        return PortholeZoom(scale: s, offset: CGSize(width: to.x - q.x * s, height: to.y - q.y * s)).clamped(to: bounds)
    }

    /// `start` moved by a two-finger drag's `translation`, clamped to the panel.
    static func panned(from start: PortholeZoom, by translation: CGPoint, in bounds: CGSize) -> PortholeZoom {
        PortholeZoom(scale: start.scale, offset: CGSize(width: start.offset.width + translation.x,
                                                        height: start.offset.height + translation.y)).clamped(to: bounds)
    }

    /// The same zoom with the picture covering the whole panel: no edge comes inside it. Back to none
    /// at 1×.
    func clamped(to bounds: CGSize) -> PortholeZoom {
        guard isZoomed, bounds.width > 0, bounds.height > 0 else { return .none }
        let w = bounds.width, h = bounds.height
        return PortholeZoom(scale: scale, offset: CGSize(width: min(max(offset.width, w - w * scale), 0),
                                                        height: min(max(offset.height, h - h * scale), 0)))
    }
}
