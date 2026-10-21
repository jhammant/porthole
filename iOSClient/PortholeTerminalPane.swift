import SwiftUI
import UIKit
import StreamProtocol

/// Porthole (docs/agent-view-plan.md): a text mode in the detail panel. Draws the host's screen (kind 206)
/// cell by cell on a fixed grid, each cell in the colour the host sent (Claude Code's own, or iTerm's
/// palette), in Jon's iTerm font, Hack Nerd Font Mono (bundled). Sized to the panel: the host's terminal gets the columns and rows that fit (kind 205), and
/// again when the panel changes. Keys go back as a terminal would send them (kind 207); ⌃⌥ hot keys stay
/// Porthole's.
struct PortholeTerminalPane: View {
    @ObservedObject var client: StreamClient
    @ObservedObject private var matrix = PortholeMatrix.shared
    let terminalID: String
    /// A session's iTerm window, so the host finds the session in one step; nil for the agent view.
    var windowID: UInt32? = nil
    var title: String = "Agent view"

    var body: some View {
        GeometryReader { geo in
            PortholeTerminalRepresentable(client: client, terminalID: terminalID, size: geo.size)
                .onAppear { client.openTerminalPane(terminalID); watch(geo.size) }
                .onChange(of: geo.size) { _, size in watch(size) }
                .overlay { if matrix.on { PortholeMatrixRain(opacity: 0.16) } }
        }
        .background(Color(rgb: client.porthole.terminals[terminalID]?.background ?? 0))
        .onDisappear { client.closeTerminalPane(terminalID) }
        .accessibilityLabel(title)
    }

    private func watch(_ size: CGSize) {
        let grid = PortholeTerminalMetrics.standard.grid(for: size)
        guard grid.columns > 0, grid.rows > 0 else { return }
        client.watchTerminal(terminalID, windowID: windowID, fit: grid)
    }
}

/// The font and the cell it makes.
struct PortholeTerminalMetrics {
    let font: UIFont
    let bold: UIFont
    let cell: CGSize
    static let inset: CGFloat = 8

    static let standard = PortholeTerminalMetrics(size: 13)

    init(size: CGFloat) {
        // Jon's iTerm font, bundled (docs/HackNerdFont-LICENSE.md): Hack Nerd Font Mono, Regular and Bold.
        font = UIFont(name: "HackNFM-Regular", size: size) ?? UIFont(name: "Menlo-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        bold = UIFont(name: "HackNFM-Bold", size: size) ?? UIFont(name: "Menlo-Bold", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .bold)
        let advance = ("M" as NSString).size(withAttributes: [.font: font]).width
        cell = CGSize(width: advance.rounded(.up), height: (font.lineHeight).rounded(.up))
    }

    /// The columns and rows that fit a panel of `size`, inside the inset.
    func grid(for size: CGSize) -> (columns: Int, rows: Int) {
        (Int(((size.width - 2 * Self.inset) / cell.width).rounded(.down)), Int(((size.height - 2 * Self.inset) / cell.height).rounded(.down)))
    }
}

private struct PortholeTerminalRepresentable: UIViewRepresentable {
    @ObservedObject var client: StreamClient
    @ObservedObject private var matrix = PortholeMatrix.shared
    let terminalID: String
    let size: CGSize

    func makeUIView(context: Context) -> PortholeTerminalView {
        let view = PortholeTerminalView()
        view.send = { [weak client] text in client?.sendTerminal(text, to: terminalID) }
        // With a hardware keyboard the pane takes its keys at once; without, a tap brings the software
        // keyboard up, rather than it covering half the screen as the pane opens.
        if HardwareKeyboardMonitor.shared.attached { DispatchQueue.main.async { view.becomeFirstResponder() } }
        return view
    }

    func updateUIView(_ view: PortholeTerminalView, context: Context) {
        view.send = { [weak client] text in client?.sendTerminal(text, to: terminalID) }
        view.matrix = matrix.on
        if let state = client.porthole.terminals[terminalID] { view.show(state) }
    }
}

/// The grid itself: draws the screen and takes the keyboard.
final class PortholeTerminalView: UIView, UIKeyInput {
    var send: (String) -> Void = { _ in }
    /// The hidden matrix mode: every colour green, as bright as it was, on black.
    var matrix = false { didSet { if matrix != oldValue { setNeedsDisplay() } } }
    private var state: PortholeTerminalState?
    private let metrics = PortholeTerminalMetrics.standard

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        contentMode = .redraw
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() { becomeFirstResponder() }

    func show(_ new: PortholeTerminalState) {
        guard new.version != state?.version || new.id != state?.id else { return }
        state = new
        backgroundColor = matrix ? .black : UIColor(rgb: new.background)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let state, let ctx = UIGraphicsGetCurrentContext() else { return }
        let cw = metrics.cell.width, ch = metrics.cell.height, inset = PortholeTerminalMetrics.inset
        let colour: (UInt32, Bool) -> UIColor = { [matrix] rgb, isBackground in
            guard matrix else { return UIColor(rgb: rgb) }
            return isBackground ? PortholeMatrix.green(rgb, floor: 0).withAlphaComponent(rgb == state.background ? 0 : 0.35) : PortholeMatrix.green(rgb)
        }
        ctx.setFillColor(matrix ? UIColor.black.cgColor : UIColor(rgb: state.background).cgColor)
        ctx.fill(bounds)
        let firstRow = max(0, Int(((rect.minY - inset) / ch).rounded(.down)))
        let lastRow = min(state.runs.count - 1, Int(((rect.maxY - inset) / ch).rounded(.up)))
        guard firstRow <= lastRow else { return }
        for row in firstRow...lastRow {
            var col = 0
            let y = inset + CGFloat(row) * ch
            for run in state.runs[row] {
                let flags = run.style ?? 0
                var fg = run.fg ?? state.foreground, bg = run.bg
                if flags & 8 != 0 { let f = fg; fg = bg ?? state.background; bg = f }
                var attrs: [NSAttributedString.Key: Any] = [.font: flags & 1 != 0 ? metrics.bold : metrics.font,
                                                            .foregroundColor: colour(fg, false).withAlphaComponent(flags & 16 != 0 ? 0.6 : 1)]
                if flags & 4 != 0 { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if flags & 32 != 0 { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if flags & 2 != 0 { attrs[.obliqueness] = 0.18 }
                for character in run.text {
                    let wide = Self.isWide(character)
                    let x = inset + CGFloat(col) * cw
                    let width = cw * (wide ? 2 : 1)
                    if let bg {
                        ctx.setFillColor(colour(bg, true).cgColor)
                        ctx.fill(CGRect(x: x, y: y, width: width, height: ch))
                    }
                    if let quads = Self.blockQuadrants(character) {
                        // Block elements (Claude Code's mascot, bars) as solid shapes that meet their
                        // neighbours: a font's block glyphs leave hairline gaps between rows.
                        ctx.setFillColor((attrs[.foregroundColor] as? UIColor ?? .white).cgColor)
                        let hw = width / 2, hh = ch / 2
                        for (i, q) in [CGRect(x: x, y: y, width: hw, height: hh), CGRect(x: x + hw, y: y, width: hw, height: hh),
                                       CGRect(x: x, y: y + hh, width: hw, height: hh), CGRect(x: x + hw, y: y + hh, width: hw, height: hh)].enumerated()
                            where quads & (1 << i) != 0 {
                            ctx.fill(q.insetBy(dx: -0.25, dy: -0.25))
                        }
                    } else if character != " " {
                        let s = String(Self.drawable(character)) as NSString
                        // A glyph the face lacks comes from a fallback font of another width: centred in its
                        // cells, so the grid stays the grid.
                        let w = s.size(withAttributes: attrs).width
                        s.draw(at: CGPoint(x: x + (width - w) / 2, y: y), withAttributes: attrs)
                    }
                    col += wide ? 2 : 1
                }
            }
        }
        if let c = state.cursor, c.y >= firstRow, c.y <= lastRow {
            ctx.setFillColor(colour(state.foreground, false).withAlphaComponent(0.55).cgColor)
            ctx.fill(CGRect(x: inset + CGFloat(c.x) * cw, y: inset + CGFloat(c.y) * ch, width: cw, height: ch))
        }
    }

    /// Claude Code's marks that Hack lacks, drawn as the nearest it has: a fallback font's glyph is wider
    /// than the cell and came out clipped (⏺ as a sliver).
    static func drawable(_ c: Character) -> Character {
        switch c {
        case "⏺": return "●"
        case "⎿": return "└"
        case "⏵": return "▸"
        case "⏸": return "‖"
        default: return c
        }
    }

    /// The quadrants a block element fills (1 top left, 2 top right, 4 bottom left, 8 bottom right), or
    /// nil for any other character.
    static func blockQuadrants(_ c: Character) -> Int? {
        guard let v = c.unicodeScalars.first?.value, c.unicodeScalars.count == 1 else { return nil }
        switch v {
        case 0x2588: return 15                      // █
        case 0x2580: return 3                       // ▀
        case 0x2584: return 12                      // ▄
        case 0x258C: return 5                       // ▌
        case 0x2590: return 10                      // ▐
        case 0x2596: return 4                       // ▖
        case 0x2597: return 8                       // ▗
        case 0x2598: return 1                       // ▘
        case 0x2599: return 1 | 4 | 8               // ▙
        case 0x259A: return 1 | 8                   // ▚
        case 0x259B: return 1 | 2 | 4               // ▛
        case 0x259C: return 1 | 2 | 8               // ▜
        case 0x259D: return 2                       // ▝
        case 0x259E: return 2 | 4                   // ▞
        case 0x259F: return 2 | 4 | 8               // ▟
        default: return nil
        }
    }

    /// East Asian wide characters and emoji take two cells, as the host's terminal counts them.
    static func isWide(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        switch v {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    // MARK: Keys

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    func insertText(_ text: String) { send(text.replacingOccurrences(of: "\n", with: "\r")) }
    func deleteBackward() { send("\u{7f}") }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let hotKeys = PortholeHotKeys.claim(presses, down: true)
        var rest: Set<UIPress> = []
        for press in presses.subtracting(hotKeys) {
            if let key = press.key, let bytes = Self.bytes(for: key) { send(bytes) } else { rest.insert(press) }
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.subtracting(PortholeHotKeys.claim(presses, down: false))
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    /// What a terminal sends for the keys UIKeyInput doesn't cover: arrows, Escape, Tab, Return and
    /// Control with a letter. Nil leaves the key to insertText and deleteBackward.
    static func bytes(for key: UIKey) -> String? {
        let flags = key.modifierFlags
        switch key.keyCode {
        case .keyboardUpArrow: return "\u{1b}[A"
        case .keyboardDownArrow: return "\u{1b}[B"
        case .keyboardRightArrow: return "\u{1b}[C"
        case .keyboardLeftArrow: return "\u{1b}[D"
        case .keyboardEscape: return "\u{1b}"
        case .keyboardTab: return flags.contains(.shift) ? "\u{1b}[Z" : "\t"
        case .keyboardReturnOrEnter: return "\r"
        case .keyboardDeleteOrBackspace: return "\u{7f}"
        case .keyboardHome: return "\u{1b}[H"
        case .keyboardEnd: return "\u{1b}[F"
        case .keyboardPageUp: return "\u{1b}[5~"
        case .keyboardPageDown: return "\u{1b}[6~"
        default: break
        }
        if flags.contains(.control), !flags.contains(.alternate), !flags.contains(.command),
           let c = key.charactersIgnoringModifiers.lowercased().unicodeScalars.first, c.value >= 0x61, c.value <= 0x7A {
            return String(UnicodeScalar(UInt8(c.value - 0x60)))
        }
        return nil
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(rgb: UInt32) { self.init(uiColor: UIColor(rgb: rgb)) }
}
