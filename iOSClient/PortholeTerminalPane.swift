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

    /// Porthole (22 Oct): the find bar over the pane, and what it looks for.
    @State private var findShown = false
    @State private var findText = ""
    @State private var findTyping: Task<Void, Never>?
    @FocusState private var findFocused: Bool

    private var state: PortholeTerminalState? { client.porthole.terminals[terminalID] }
    /// A session's pane scrolls and finds; the agent view's has no history.
    private var searchable: Bool { terminalID != PortholeShell.agentViewID }

    var body: some View {
        GeometryReader { geo in
            PortholeTerminalRepresentable(client: client, terminalID: terminalID, size: geo.size, openFind: { openFind() })
                .onAppear {
                    client.openTerminalPane(terminalID)
                    watch(geo.size)
                    // A search result tapped: the pane opens at its words.
                    if let q = client.porthole.pendingFind.removeValue(forKey: terminalID) { findText = q; findShown = true; client.findInTerminal(terminalID, q) }
                }
                .onChange(of: geo.size) { _, size in watch(size) }
                .overlay { if matrix.on { PortholeMatrixRain(opacity: 0.16) } }
                .overlay(alignment: .top) { if findShown { findBar } }
                .overlay(alignment: .topTrailing) {
                    if searchable, !findShown {
                        Button { openFind() } label: {
                            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold))
                                .frame(width: 30, height: 30)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary).padding(6)
                        .accessibilityLabel("Find in this session")
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let up = state?.scrolledUp, up > 0 {
                        Button { client.scrollTerminal(terminalID, to: 0) } label: {
                            Label("\(up) lines up · Live", systemImage: "arrow.down.to.line")
                                .font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 7)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain).padding(10)
                        .accessibilityLabel("Back to the live screen, \(up) lines up")
                    }
                }
                .onChange(of: client.porthole.pendingFind[terminalID]) { _, q in
                    guard let q else { return }
                    client.porthole.pendingFind[terminalID] = nil
                    findText = q; findShown = true
                    client.findInTerminal(terminalID, q)
                }
        }
        .background(Color(rgb: state?.background ?? 0))
        .onDisappear { client.closeTerminalPane(terminalID) }
        .accessibilityLabel(title)
    }

    private func openFind() {
        guard searchable else { return }
        withAnimation(.easeOut(duration: 0.15)) { findShown = true }
        findFocused = true
    }

    private func closeFind() {
        findTyping?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { findShown = false }
        findFocused = false
        client.endFind(terminalID)
    }

    /// Words, how many matches and which is shown, older and newer, and Done.
    private var findBar: some View {
        let find = state?.find
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in this session", text: $findText)
                .textFieldStyle(.plain).autocorrectionDisabled().textInputAutocapitalization(.never)
                .focused($findFocused)
                .submitLabel(.search)
                .onSubmit {
                    // Return: the match before (up, older), as a new find when the words changed.
                    client.findInTerminal(terminalID, findText, step: find?.query == findText.trimmingCharacters(in: .whitespaces) ? -1 : 0)
                    findFocused = true
                }
                .onChange(of: findText) { _, text in
                    findTyping?.cancel()
                    findTyping = Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        guard !Task.isCancelled else { return }
                        client.findInTerminal(terminalID, text)
                    }
                }
                .onKeyPress(.escape) { closeFind(); return .handled }
            if let find, !find.query.isEmpty {
                Text(find.count == 0 ? "No matches" : "\(find.index) of \(find.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
            }
            Button { client.findInTerminal(terminalID, findText, step: -1) } label: { Image(systemName: "chevron.up") }
                .accessibilityLabel("Earlier match").disabled((find?.count ?? 0) == 0)
            Button { client.findInTerminal(terminalID, findText, step: 1) } label: { Image(systemName: "chevron.down") }
                .accessibilityLabel("Later match").disabled((find?.count ?? 0) == 0)
            Button("Done") { closeFind() }.font(.callout.weight(.semibold))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(8)
        .transition(.move(edge: .top).combined(with: .opacity))
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
    var openFind: () -> Void = {}

    func makeUIView(context: Context) -> PortholeTerminalView {
        let view = PortholeTerminalView()
        view.send = { [weak client] text in client?.sendTerminal(text, to: terminalID) }
        view.scroll = { [weak client] lines in client?.scrollTerminal(terminalID, to: lines) }
        view.openFind = openFind
        // With a hardware keyboard the pane takes its keys at once; without, a tap brings the software
        // keyboard up, rather than it covering half the screen as the pane opens.
        if HardwareKeyboardMonitor.shared.attached { DispatchQueue.main.async { view.becomeFirstResponder() } }
        return view
    }

    func updateUIView(_ view: PortholeTerminalView, context: Context) {
        view.send = { [weak client] text in client?.sendTerminal(text, to: terminalID) }
        view.openFind = openFind
        view.matrix = matrix.on
        if let state = client.porthole.terminals[terminalID] { view.show(state) }
    }
}

/// The grid itself: draws the screen and takes the keyboard.
final class PortholeTerminalView: UIView, UIKeyInput, UIGestureRecognizerDelegate {
    var send: (String) -> Void = { _ in }
    /// Porthole (22 Oct, "scroll the window up with two fingers"): the lines up from the live screen the
    /// pane wants, as one or two fingers, a trackpad or a mouse's wheel move it; and ⌘F's find.
    var scroll: (Int) -> Void = { _ in }
    var openFind: () -> Void = {}
    /// The hidden matrix mode: every colour green, as bright as it was, on black.
    var matrix = false { didSet { if matrix != oldValue { setNeedsDisplay() } } }
    private var state: PortholeTerminalState?
    private let metrics = PortholeTerminalMetrics.standard

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        contentMode = .redraw
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(longPressed)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned))
        pan.delegate = self
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 2
        pan.allowedScrollTypesMask = .all
        addGestureRecognizer(pan)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() {
        if selection != nil { selection = nil; return }
        becomeFirstResponder()
    }

    /// While a selection is being dragged out the finger selects; it scrolls nothing.
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g is UIPanGestureRecognizer, selecting { return false }
        return super.gestureRecognizerShouldBegin(g)
    }

    // MARK: Porthole: selecting lines to copy (31 Oct, "I can't do multi line copy")

    /// Held, then dragged: from the cell held to the cell under the finger, in reading order.
    private var selection: (from: PortholeTextSelection.Cell, to: PortholeTextSelection.Cell)? { didSet { setNeedsDisplay() } }
    private var selecting = false

    private func cell(at p: CGPoint) -> PortholeTextSelection.Cell {
        let inset = PortholeTerminalMetrics.inset
        let rows = max((state?.rows ?? 1) - 1, 0)
        return .init(row: min(max(Int(((p.y - inset) / metrics.cell.height).rounded(.down)), 0), rows),
                     column: max(Int(((p.x - inset) / metrics.cell.width).rounded(.down)), 0))
    }

    // MARK: Porthole: scrolling the session's history

    private var panStart = 0
    private var wanted: Int?
    private var lastSent: Int?
    private var sendTimer: Timer?

    /// Content follows the finger: down shows older lines. A line a cell's height; sent at most every
    /// 50 ms, the last always.
    @objc private func panned(_ g: UIPanGestureRecognizer) {
        guard let state, let history = state.history else { return }
        switch g.state {
        case .began:
            panStart = state.scrolledUp
            lastSent = state.scrolledUp
        case .changed, .ended:
            let lines = min(history, max(0, panStart + Int((g.translation(in: self).y / metrics.cell.height).rounded())))
            wanted = lines
            if g.state == .ended { flushScroll(); return }
            if sendTimer == nil {
                flushScroll()
                sendTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
                    self?.sendTimer = nil
                    self?.flushScroll()
                }
            }
        default:
            break
        }
    }

    private func flushScroll() {
        guard let wanted, wanted != lastSent else { return }
        lastSent = wanted
        scroll(wanted)
    }

    // MARK: Porthole: held keys repeat

    /// Delete, the arrows and the page keys repeat while held, at a Mac's pace: iPadOS repeats only what
    /// its text system types, and this view sends these itself (22 Oct: "key repeat, especially on delete,
    /// doesn't work that well").
    private var repeating: (key: UIKeyboardHIDUsage, timer: Timer)?
    static let repeatDelay = 0.35
    static let repeatInterval = 0.035

    private func startRepeat(_ key: UIKey, bytes: String) {
        stopRepeat()
        guard Self.repeats(key.keyCode) else { return }
        let code = key.keyCode
        let timer = Timer.scheduledTimer(withTimeInterval: Self.repeatDelay, repeats: false) { [weak self] _ in
            guard let self, self.repeating?.key == code else { return }
            self.send(bytes)
            let again = Timer.scheduledTimer(withTimeInterval: Self.repeatInterval, repeats: true) { [weak self] _ in self?.send(bytes) }
            self.repeating = (code, again)
        }
        repeating = (code, timer)
    }

    private func stopRepeat(_ key: UIKeyboardHIDUsage? = nil) {
        guard let r = repeating, key == nil || r.key == key else { return }
        r.timer.invalidate()
        repeating = nil
    }

    static func repeats(_ code: UIKeyboardHIDUsage) -> Bool {
        [.keyboardDeleteOrBackspace, .keyboardDeleteForward, .keyboardUpArrow, .keyboardDownArrow, .keyboardLeftArrow,
         .keyboardRightArrow, .keyboardPageUp, .keyboardPageDown].contains(code)
    }

    override func resignFirstResponder() -> Bool {
        stopRepeat()
        return super.resignFirstResponder()
    }

    func show(_ new: PortholeTerminalState) {
        guard new.version != state?.version || new.id != state?.id else { return }
        // Scrolled elsewhere, the selected cells hold other words: let it go.
        if selection != nil, !selecting, new.scrolledUp != state?.scrolledUp { selection = nil }
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
        // Porthole: the lines being selected to copy.
        if let selection {
            let (a, b) = PortholeTextSelection.ordered(selection.from, selection.to)
            ctx.setFillColor(UIColor.systemBlue.withAlphaComponent(0.32).cgColor)
            let lo = max(a.row, firstRow), hi = min(b.row, lastRow)
            for row in lo...max(hi, lo) where row <= hi {
                let start = row == a.row ? a.column : 0
                let end = row == b.row ? min(b.column, state.columns - 1) : state.columns - 1
                guard end >= start else { continue }
                ctx.fill(CGRect(x: inset + CGFloat(start) * cw, y: inset + CGFloat(row) * ch, width: CGFloat(end - start + 1) * cw, height: ch))
            }
        }
        // Porthole: the find's matches on this screen, the one shown brighter.
        for hit in state.find?.hits ?? [] where hit.row >= firstRow && hit.row <= lastRow {
            let r = CGRect(x: inset + CGFloat(hit.column) * cw - 1, y: inset + CGFloat(hit.row) * ch,
                           width: CGFloat(max(1, hit.length)) * cw + 2, height: ch)
            ctx.setFillColor(UIColor.systemYellow.withAlphaComponent(hit.current ? 0.5 : 0.22).cgColor)
            ctx.addPath(UIBezierPath(roundedRect: r, cornerRadius: 3).cgPath)
            ctx.fillPath()
            if hit.current {
                ctx.setStrokeColor(UIColor.systemOrange.cgColor)
                ctx.setLineWidth(1.5)
                ctx.addPath(UIBezierPath(roundedRect: r, cornerRadius: 3).cgPath)
                ctx.strokePath()
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

    // Porthole (22 Oct review): a terminal takes what is typed as typed: no smart quotes or dashes, no
    // capitals or corrections, as the stream's input view has it.
    @objc var keyboardType: UIKeyboardType = .asciiCapable
    @objc var autocorrectionType: UITextAutocorrectionType = .no
    @objc var autocapitalizationType: UITextAutocapitalizationType = .none
    @objc var smartQuotesType: UITextSmartQuotesType = .no
    @objc var smartDashesType: UITextSmartDashesType = .no
    @objc var spellCheckingType: UITextSpellCheckingType = .no

    // MARK: Porthole: paste and copy

    /// ⌘V, or Paste from the long-press menu: the clipboard as a bracketed paste, so a multi-line paste
    /// arrives whole in Claude's prompt instead of sending at its first line.
    override func paste(_ sender: Any?) {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        let clean = text.replacingOccurrences(of: "\u{1b}", with: "")
        send("\u{1b}[200~" + clean + "\u{1b}[201~")
    }

    /// The screen's text (Copy from the long-press menu).
    /// The selection, or the whole screen without one.
    override func copy(_ sender: Any?) {
        guard let state else { return }
        if let selection {
            UIPasteboard.general.string = PortholeTextSelection.text(state.lines, from: selection.from, to: selection.to, wide: Self.isWide)
            self.selection = nil
            return
        }
        UIPasteboard.general.string = state.lines.map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    /// Porthole: ⌘` and the like ahead of iPadOS (PortholeHotKeys.priorityCommands).
    override var keyCommands: [UIKeyCommand]? { (super.keyCommands ?? []) + (isFirstResponder ? PortholeHotKeys.priorityCommands : []) }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(UIResponder.portholePriorityKey(_:)) { return true }
        if action == #selector(paste(_:)) { return UIPasteboard.general.hasStrings }
        if action == #selector(copy(_:)) { return state != nil }
        return false
    }

    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        let at = g.location(in: self)
        switch g.state {
        case .began:
            becomeFirstResponder()
            selecting = true
            let c = cell(at: at)
            // Held still, the whole line; dragged on, from where the finger was held.
            selection = (.init(row: c.row, column: 0), .init(row: c.row, column: Int.max))
            anchor = c
        case .changed:
            guard let anchor else { return }
            let c = cell(at: at)
            if c != anchor { selection = (anchor, c) }
        case .ended:
            selecting = false
            editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: at))
        default:
            selecting = false
        }
    }
    private var anchor: PortholeTextSelection.Cell?

    private lazy var editMenu: UIEditMenuInteraction = {
        let i = UIEditMenuInteraction(delegate: nil)
        addInteraction(i)
        return i
    }()

    // MARK: Porthole: the keys a touch keyboard lacks

    /// Over the on-screen keyboard: Esc (interrupt Claude), ⇧⇥ (accept edits on or off), ⇥, the arrows
    /// (through Claude's options), ^C and Return (22 Oct review: none of these could be typed on an iPhone).
    override var inputAccessoryView: UIView? { HardwareKeyboardMonitor.shared.attached ? nil : keyRow }

    private lazy var keyRow: UIView = {
        let keys: [(String, String, String)] = [("esc", "\u{1b}", "Escape"), ("⇧⇥", "\u{1b}[Z", "Shift Tab"), ("⇥", "\t", "Tab"),
                                                ("←", "\u{1b}[D", "Left"), ("↑", "\u{1b}[A", "Up"), ("↓", "\u{1b}[B", "Down"),
                                                ("→", "\u{1b}[C", "Right"), ("^C", "\u{3}", "Control C"), ("⏎", "\r", "Return")]
        let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: 0, height: 46), inputViewStyle: .keyboard)
        bar.allowsSelfSizing = true
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (label, bytes, name) in keys {
            var config = UIButton.Configuration.gray()
            config.title = label
            config.cornerStyle = .medium
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
                var a = a; a.font = .monospacedSystemFont(ofSize: 15, weight: .medium); return a
            }
            let b = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.send(bytes) })
            b.accessibilityLabel = name
            stack.addArrangedSubview(b)
        }
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -5),
            bar.heightAnchor.constraint(equalToConstant: 46),
        ])
        return bar
    }()

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let hotKeys = PortholeHotKeys.claim(presses, down: true)
        var rest: Set<UIPress> = []
        for press in presses.subtracting(hotKeys) {
            // ⌘F: find in this session, as in iTerm.
            if let key = press.key, key.keyCode == .keyboardF, key.modifierFlags.contains(.command) { openFind(); continue }
            if let key = press.key, let bytes = Self.bytes(for: key) { send(bytes); startRepeat(key, bytes: bytes) } else { rest.insert(press) }
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses { if let key = press.key { stopRepeat(key.keyCode) } }
        let rest = presses.subtracting(PortholeHotKeys.claim(presses, down: false))
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses { if let key = press.key { stopRepeat(key.keyCode) } }
        super.pressesCancelled(presses, with: event)
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
