import SwiftUI
import UIKit

/// The hidden matrix mode (Jon, 21 Oct 2026: "a hidden easter egg 'matrix' mode"). Five quick taps on the
/// Mac's name at the top of the sidebar: a few seconds of "Wake up, Jon…", then green rain behind the
/// sidebar and every text mode drawn green on black. The same taps leave it. Not kept across launches.
final class PortholeMatrix: ObservableObject {
    static let shared = PortholeMatrix()
    @Published private(set) var on = false
    @Published private(set) var introAt: Date?

    func toggle() {
        on.toggle()
        introAt = on ? Date() : nil
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    /// A terminal colour as the matrix draws it: green, as bright as the colour was.
    static func green(_ rgb: UInt32, floor: Double = 0.32) -> UIColor {
        let r = Double((rgb >> 16) & 0xFF) / 255, g = Double((rgb >> 8) & 0xFF) / 255, b = Double(rgb & 0xFF) / 255
        let lum = max(floor, min(1, 0.2126 * r + 0.7152 * g + 0.0722 * b + 0.25))
        return UIColor(red: 0.08 * lum, green: lum, blue: 0.25 * lum, alpha: 1)
    }
}

/// Falling glyphs, a pure function of time: each column has its own speed and start, and each glyph
/// changes now and then. Nothing to keep between frames.
struct PortholeMatrixRain: View {
    var opacity: Double = 0.35
    private static let glyphs = Array("ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝ0123456789:.=*+-<>¦")
    private static let cell: CGFloat = 16

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let columns = Int(size.width / Self.cell) + 1
                let rows = Int(size.height / Self.cell) + 1
                for col in 0..<columns {
                    let seed = Self.hash(col)
                    let speed = 6 + Double(seed % 9)                     // rows a second
                    let length = 8 + Int(seed % 14)
                    let span = Double(rows + length)
                    let head = (t * speed + Double(seed % 997)).truncatingRemainder(dividingBy: span)
                    for k in 0..<length {
                        let row = Int(head) - k
                        guard row >= 0, row < rows else { continue }
                        let change = Int(t * 4) + k
                        let glyph = Self.glyphs[Self.hash(col &* 31 &+ row &* 17 &+ change / 3) % Self.glyphs.count]
                        let fade = 1 - Double(k) / Double(length)
                        let colour = k == 0 ? Color(red: 0.75, green: 1, blue: 0.8) : Color(red: 0, green: 0.85, blue: 0.3)
                        ctx.draw(Text(String(glyph)).font(.system(size: 14, design: .monospaced)).foregroundColor(colour.opacity(fade)),
                                 at: CGPoint(x: CGFloat(col) * Self.cell + Self.cell / 2, y: CGFloat(row) * Self.cell + Self.cell / 2))
                    }
                }
            }
        }
        .opacity(opacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static func hash(_ n: Int) -> Int {
        var x = UInt64(bitPattern: Int64(n)) &+ 0x9E3779B97F4A7C15
        x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9
        x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
        return Int(truncatingIfNeeded: (x ^ (x >> 31)) & 0x7FFF_FFFF)
    }
}

/// The way in: the lines typed out on black over the whole screen, then gone.
struct PortholeMatrixIntro: View {
    let start: Date
    private static let lines = ["Wake up, Jon…", "The Matrix has you…", "Follow the white rabbit.", "Knock, knock."]
    static let duration: TimeInterval = 6.6

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(start)
            if elapsed < Self.duration {
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(elapsed > Self.duration - 0.6 ? (Self.duration - elapsed) / 0.6 : 1)
                    Text(Self.typed(at: elapsed))
                        .font(.custom("HackNFM-Regular", size: 22))
                        .foregroundStyle(Color(red: 0.1, green: 1, blue: 0.35))
                        .padding(40)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
        }
    }

    /// One line at a time, a character every 60 ms, each line held for a moment before the next.
    static func typed(at elapsed: TimeInterval) -> String {
        var t = elapsed
        for line in lines {
            let typing = Double(line.count) * 0.06
            if t < typing { return String(line.prefix(Int(t / 0.06))) + "▌" }
            t -= typing
            if t < 0.45 { return line + (Int(elapsed * 3) % 2 == 0 ? "▌" : "") }
            t -= 0.45
        }
        return lines.last ?? ""
    }
}
