import SwiftUI
import UIKit
import StreamProtocol

/// The iPhone Duo as a tiny laptop (Jon, 21 Oct 2026: "like a tiny old school laptop I can use folded, with
/// the screen as the keyboard"; the phone arrives 23 Oct). Half-folded, the lower half is a Mac keyboard,
/// with a slim trackpad strip under it or keys alone (`Deck`, his "1 & 2"; the key at the bottom left
/// switches). With his folding keyboard and mouse connected the lower half goes back to the picture
/// (PortraitStreamScreen). Each key goes to the Mac as a keyboard sends it (KeyChord); ctrl, opt, cmd and
/// shift latch for the next key, shared with the trackpad's click (`latched`); shift twice is caps lock;
/// delete and the arrows repeat while held.
struct PortholeLaptopKeyboard: View {
    enum Deck: String { case keyboardAndTrackpad, keyboardOnly }

    @Binding var latched: KeyModifiers
    @Binding var deck: Deck
    let send: (InputEvent) -> Void
    @State private var capsLock = false
    @State private var lastShiftTap: Date = .distantPast

    /// On the Duo's inner display (an iPhone's halves layout is only ever the Duo's) or with DEBUG
    /// `-PortholeLaptopKeyboard 1` (the harness on an iPad simulator).
    static var applies: Bool {
        #if DEBUG
        if UserDefaults.standard.object(forKey: "PortholeLaptopKeyboard") != nil { return UserDefaults.standard.bool(forKey: "PortholeLaptopKeyboard") }
        #endif
        return UIDevice.current.userInterfaceIdiom == .phone
    }

    struct Key: Identifiable {
        enum Kind { case char(Character, shifted: Character), usage(UInt16), modifier(KeyModifiers), shift, deck }
        let id = UUID()
        let label: String
        var kind: Kind
        var width: CGFloat = 1
        var repeats = false
    }

    static func chars(_ s: String, _ shifted: String) -> [Key] {
        zip(s, shifted).map { Key(label: String($0), kind: .char($0, shifted: $1)) }
    }

    /// A Mac's US layout in 15 units a row.
    static let rows: [[Key]] = [
        [Key(label: "esc", kind: .usage(HIDKey.escape))] + chars("`1234567890-=", "~!@#$%^&*()_+")
            + [Key(label: "⌫", kind: .usage(HIDKey.deleteBackward), width: 1, repeats: true)],
        [Key(label: "tab", kind: .usage(HIDKey.tab), width: 1.5)] + chars("qwertyuiop[]", "QWERTYUIOP{}")
            + chars("\\", "|").map { var k = $0; k.width = 1.5; return k },
        [Key(label: "ctrl", kind: .modifier(.control), width: 1.75)] + chars("asdfghjkl;'", "ASDFGHJKL:\"")
            + [Key(label: "return", kind: .usage(0x28), width: 2.25)],
        [Key(label: "shift", kind: .shift, width: 2.25)] + chars("zxcvbnm,./", "ZXCVBNM<>?")
            + [Key(label: "shift", kind: .shift, width: 2.75)],
        [Key(label: "deck", kind: .deck), Key(label: "opt", kind: .modifier(.option), width: 1.25),
         Key(label: "cmd", kind: .modifier(.command), width: 1.5), Key(label: " ", kind: .char(" ", shifted: " "), width: 6.75),
         Key(label: "cmd", kind: .modifier(.command), width: 1.5),
         Key(label: "←", kind: .usage(HIDKey.leftArrow), repeats: true), Key(label: "↑↓", kind: .usage(0)),
         Key(label: "→", kind: .usage(HIDKey.rightArrow), repeats: true)],
    ]

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 4
            let unit = (geo.size.width - gap * 14) / 15
            let rowHeight = (geo.size.height - gap * CGFloat(Self.rows.count - 1)) / CGFloat(Self.rows.count)
            VStack(spacing: gap) {
                ForEach(Array(Self.rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: gap) {
                        ForEach(row) { key in
                            let width = unit * key.width + gap * (key.width - 1)
                            if key.label == "↑↓" {
                                VStack(spacing: 2) {
                                    cap(Key(label: "↑", kind: .usage(HIDKey.upArrow), repeats: true), width: width, height: (rowHeight - 2) / 2)
                                    cap(Key(label: "↓", kind: .usage(HIDKey.downArrow), repeats: true), width: width, height: (rowHeight - 2) / 2)
                                }
                            } else {
                                cap(key, width: width, height: rowHeight)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mac keyboard")
    }

    private var shifted: Bool { capsLock || latched.contains(.shift) }

    @ViewBuilder
    private func cap(_ key: Key, width: CGFloat, height: CGFloat) -> some View {
        let lit: Bool = {
            switch key.kind {
            case .modifier(let m): return latched.contains(m)
            case .shift: return shifted
            case .deck: return deck == .keyboardOnly
            default: return false
            }
        }()
        PortholeKeyCap(width: width, height: height, lit: lit, repeats: key.repeats, action: { press(key) }) {
            switch key.kind {
            case .char(let c, let s):
                Text(c == " " ? "" : String(shifted ? s : c)).font(.system(size: height > 44 ? 17 : 15, weight: .regular))
            case .deck:
                Image(systemName: deck == .keyboardOnly ? "keyboard" : "rectangle.bottomhalf.inset.filled").font(.system(size: 14))
            case .shift:
                Image(systemName: capsLock ? "capslock.fill" : "shift").font(.system(size: 14))
            default:
                Text(key.label).font(.system(size: key.label.count > 2 ? 12 : 16, weight: .medium))
            }
        }
        .accessibilityLabel(Self.spoken(key))
    }

    private func press(_ key: Key) {
        switch key.kind {
        case .char(let c, let s):
            Self.events(c, shifted: s, latched: latched, capsLock: capsLock).forEach(send)
            latched = []
        case .usage(let usage):
            guard usage != 0 else { return }
            KeyChord.press(usage, with: latched).forEach(send)
            if !key.repeats { latched = [] }
        case .modifier(let m):
            latched.formSymmetricDifference(m)
        case .shift:
            // Twice within 0.35 s: caps lock; once: shift for the next key; again with caps lock on: off.
            if capsLock { capsLock = false; latched.remove(.shift) }
            else if Date().timeIntervalSince(lastShiftTap) < 0.35 { capsLock = true; latched.remove(.shift) }
            else { latched.formSymmetricDifference(.shift) }
            lastShiftTap = Date()
        case .deck:
            deck = deck == .keyboardAndTrackpad ? .keyboardOnly : .keyboardAndTrackpad
        }
    }

    /// A character key as the Mac gets it: its usage, with shift when shift is latched (or caps lock is on
    /// and it is a letter), and whatever else is latched.
    static func events(_ c: Character, shifted s: Character, latched: KeyModifiers, capsLock: Bool) -> [InputEvent] {
        guard let usage = HIDKey.usage(for: c) else { return [] }
        var mods = latched
        if capsLock && c.isLetter && c != s { mods.insert(.shift) }
        return KeyChord.press(usage, with: mods)
    }

    #if DEBUG
    /// `-PortholeInputScript`'s `laptoptype TEXT` (ContentView): the text as the keyboard's keys would send
    /// it, a shifted character with shift latched first. "_" stands for a space.
    static func scriptEvents(_ text: String) -> [InputEvent] {
        let keys = rows.flatMap { $0 }
        return text.replacingOccurrences(of: "_", with: " ").flatMap { ch -> [InputEvent] in
            for key in keys {
                guard case .char(let c, let s) = key.kind else { continue }
                if ch == c { return events(c, shifted: s, latched: [], capsLock: false) }
                if ch == s { return events(c, shifted: s, latched: .shift, capsLock: false) }
            }
            return []
        }
    }
    #endif

    static func spoken(_ key: Key) -> String {
        switch key.kind {
        case .deck: return "Keyboard and trackpad, or keyboard only"
        case .shift: return "Shift"
        case .char(" ", _): return "Space"
        default:
            switch key.label {
            case "⌫": return "Delete"
            case "←": return "Left arrow"
            case "→": return "Right arrow"
            case "↑": return "Up arrow"
            case "↓": return "Down arrow"
            default: return key.label
            }
        }
    }
}

/// One key: lit while held (or latched), a light tap felt on the way down, and, for delete and the
/// arrows, the key again every 60 ms after 0.4 s held.
struct PortholeKeyCap<Label: View>: View {
    let width: CGFloat
    let height: CGFloat
    let lit: Bool
    let repeats: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var down = false
    @State private var repeater: Timer?

    var body: some View {
        label()
            .foregroundStyle(lit ? Palette.accent : Palette.text)
            .frame(width: max(width, 1), height: max(height, 1))
            .background(down ? Palette.panel.opacity(0.6) : Palette.control, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(lit ? Palette.accent.opacity(0.7) : Color.white.opacity(0.06)))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !down else { return }
                    down = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
                    action()
                    if repeats {
                        repeater = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
                            repeater = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { _ in action() }
                        }
                    }
                }
                .onEnded { _ in
                    down = false
                    repeater?.invalidate()
                    repeater = nil
                })
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}
