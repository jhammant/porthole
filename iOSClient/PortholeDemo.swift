import UIKit
import StreamProtocol

/// The demo Mac ("Try a demo Mac" on the connect screen): a made-up Mac with Claude Code sessions, apps and
/// pictures of its windows, so Porthole can be tried before the Mac app is installed, App Review can use it
/// without a Mac, and the store's screenshots show nobody's real work. Nothing is sent anywhere: picks only
/// change what shows, text modes show canned screens, and input goes nowhere.
enum PortholeDemo {
    static let macName = "Demo Mac"
    static let now = Date().timeIntervalSince1970

    static let windows: [WindowInfo] = [
        WindowInfo(id: 1001, title: "✳ acme · add rate limiting", appName: "iTerm2", bundleID: "com.googlecode.iterm2", width: 1200, height: 750),
        WindowInfo(id: 1002, title: "◐ acme · fix flaky test", appName: "iTerm2", bundleID: "com.googlecode.iterm2", width: 1200, height: 750),
        WindowInfo(id: 1003, title: "✳ website · pricing page", appName: "iTerm2", bundleID: "com.googlecode.iterm2", width: 1200, height: 750),
        WindowInfo(id: 1004, title: "Add rate limiting to the public API #42", appName: "Google Chrome", bundleID: "com.google.Chrome", width: 1440, height: 900),
        WindowInfo(id: 1005, title: "#eng", appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", width: 1280, height: 800),
        WindowInfo(id: 1006, title: "Inbox", appName: "Mail", bundleID: "com.apple.mail", width: 1280, height: 800),
    ]

    static let sessions: [ClaudeSession] = [
        ClaudeSession(id: "demo-1", title: "acme · add rate limiting", portal: "acme", folder: "dev/acme/api", state: .needsYou,
                      since: now - 140, windowID: 1001, windowNumber: 1, terminalID: "demo-term-1",
                      preview: "Should the limit apply per user or per API key?"),
        ClaudeSession(id: "demo-2", title: "acme · fix flaky test", portal: "acme", folder: "dev/acme/api", state: .working,
                      since: now - 300, windowID: 1002, windowNumber: 2, terminalID: "demo-term-2",
                      preview: "Running the suite 20 times to catch the flake…"),
        ClaudeSession(id: "demo-3", title: "website · pricing page", portal: "website", folder: "dev/website", state: .done,
                      since: now - 720, windowID: 1003, windowNumber: 3, terminalID: "demo-term-3",
                      preview: "The pricing page builds and every link checks out."),
        ClaudeSession(id: "demo-4", title: "notes · weekly summary", portal: "notes", folder: "notes", state: .idle,
                      since: now - 3600, windowID: nil, preview: nil),
    ]

    static let apps: [AppInfo] = [
        AppInfo(name: "Google Chrome", bundleID: "com.google.Chrome"), AppInfo(name: "iTerm2", bundleID: "com.googlecode.iterm2"),
        AppInfo(name: "Mail", bundleID: "com.apple.mail"), AppInfo(name: "Notes", bundleID: "com.apple.Notes"),
        AppInfo(name: "Slack", bundleID: "com.tinyspeck.slackmacgap"), AppInfo(name: "Xcode", bundleID: "com.apple.dt.Xcode"),
    ]

    static let tabs = BrowserTabs(bundleID: "com.google.Chrome", windows: [
        BrowserWindow(id: 1004, tabs: [
            BrowserTab(id: 1, title: "Add rate limiting to the public API #42", url: "https://github.com/acme/api/pull/42", active: true),
            BrowserTab(id: 2, title: "Rate limiting · API docs", url: "https://docs.acme.dev/rate-limits", active: false),
            BrowserTab(id: 3, title: "Status · acme", url: "https://status.acme.dev", active: false),
        ])])

    static let displays = [DisplayInfo(id: 1, name: "Built-in Retina Display", width: 1512, height: 982, main: true),
                           DisplayInfo(id: 2, name: "Studio Display", width: 2560, height: 1440, main: false)]

    /// The picture of what streams: a bundled image of that window (or the desktop).
    static func picture(for source: StreamSource) -> UIImage? {
        let name: String
        switch source {
        case .window(1001): name = "demo-terminal"
        case .window(1002), .window(1003): name = "demo-terminal-2"
        case .window(1004): name = "demo-browser"
        case .window: name = "demo-app"
        default: name = "demo-desktop"
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// A rounded square in a colour from the name, with its first letter.
    static func icon(_ name: String) -> UIImage {
        let colours: [UIColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemTeal, .systemPink, .systemIndigo]
        let colour = colours[abs(name.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }) % colours.count]
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { _ in
            colour.setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 64, height: 64), cornerRadius: 14).fill()
            let letter = String(name.prefix(1)) as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: UIColor.white]
            let size = letter.size(withAttributes: attrs)
            letter.draw(at: CGPoint(x: (64 - size.width) / 2, y: (64 - size.height) / 2), withAttributes: attrs)
        }
    }

    // MARK: Text modes

    static let fg: UInt32 = 0x839496, bg: UInt32 = 0x002B36
    static let orange: UInt32 = 0xD77757, green: UInt32 = 0x859900, blue: UInt32 = 0x268BD2, white: UInt32 = 0xEEE8D5,
        grey: UInt32 = 0x586E75, yellow: UInt32 = 0xB58900, cyan: UInt32 = 0x2AA198

    private static func r(_ t: String, _ c: UInt32? = nil, bold: Bool = false, bgc: UInt32? = nil) -> TerminalRun {
        TerminalRun(text: t, fg: c, bg: bgc, style: bold ? 1 : nil)
    }

    /// A canned screen for a text pane: Claude Code's agent view, or a session's terminal.
    static func screen(_ terminalID: String, columns: Int, rows: Int) -> PortholeTerminalState {
        let lines: [[TerminalRun]] = terminalID == PortholeShell.agentViewID ? agentView(columns) : session(terminalID, columns)
        var s = PortholeTerminalState(id: terminalID, columns: columns, rows: rows, lines: [])
        let padded = Array((lines + Array(repeating: [], count: max(0, rows - lines.count))).prefix(rows))
        s.runs = padded
        s.lines = padded.map { $0.map(\.text).joined() }
        s.foreground = fg
        s.background = bg
        s.version = Int.random(in: 1...Int.max / 2)
        return s
    }

    private static func rule(_ columns: Int) -> [TerminalRun] { [r(String(repeating: "─", count: max(10, columns - 1)), grey)] }

    private static func agentView(_ columns: Int) -> [[TerminalRun]] {
        [
            [r(" ▐▛███▜▌", orange), r("   "), r("Claude Code", white, bold: true), r(" v2.1", grey)],
            [r("▝▜█████▛▘", orange), r("  "), r("Opus · ~/dev", grey)],
            [r("  ▘▘ ▝▝", orange), r("    "), r("1 awaiting input · 1 working · 1 completed", grey)],
            [],
            [r("Awaiting input", white, bold: true)],
            [r("● ", yellow), r("acme · add rate limiting  ", white), r("Should the limit apply per user or per API key?", grey), r("  2m", grey)],
            [],
            [r("Working", white, bold: true)],
            [r("◐ ", blue), r("acme · fix flaky test     ", white), r("Running the suite 20 times to catch the flake…", grey), r("  5m", grey)],
            [],
            [r("Completed", white, bold: true)],
            [r("∙ ", green), r("website · pricing page    ", white), r("The pricing page builds and every link checks out.", grey), r("  12m", grey)],
            [],
            rule(columns),
            [r("❯ ", white), r("describe a task for a new session", grey)],
            rule(columns),
            [r("  enter to dispatch · ? for shortcuts", grey)],
        ]
    }

    private static func session(_ terminalID: String, _ columns: Int) -> [[TerminalRun]] {
        let ask = terminalID == "demo-term-1"
        var l: [[TerminalRun]] = [
            [r("> ", grey), r("Add rate limiting to the public API: 100 requests a minute per client.", white)],
            [],
            [r("⏺ ", white), r("I'll add a token-bucket limiter as middleware and wire it into the router.", fg)],
            [],
            [r("⏺ ", green), r("Read", white, bold: true), r("(src/server/router.ts)", fg)],
            [r("  ⎿  ", grey), r("Read 142 lines", grey)],
            [],
            [r("⏺ ", green), r("Write", white, bold: true), r("(src/middleware/rateLimit.ts)", fg)],
            [r("  ⎿  ", grey), r("Wrote 48 lines to src/middleware/rateLimit.ts", grey)],
            [],
            [r("⏺ ", green), r("Bash", white, bold: true), r("(npm test -- rateLimit)", fg)],
            [r("  ⎿  ", grey), r("PASS", 0x002B36, bold: true, bgc: green), r("  test/rateLimit.test.ts (6 tests)", fg)],
            [],
        ]
        if ask {
            l += [
                [r("⏺ ", white), r("The limiter is in and its tests pass. One choice before I finish:", fg)],
                [],
                [r("  Should the limit apply per user or per API key?", white, bold: true)],
                [],
                [r("  ❯ 1. ", blue), r("Per API key", blue, bold: true), r(" (a user's scripts share their key)", grey)],
                [r("    2. Per user", fg)],
                [r("    3. Both, whichever is hit first", fg)],
            ]
        } else {
            l += [[r("✻ ", orange), r("Running the suite 20 times… ", orange), r("(1m 12s · esc to interrupt)", grey)]]
        }
        l += [[], rule(columns), [r("❯ ", white)], rule(columns), [r("  ⏵⏵ accept edits on", 0x6C71C4), r(" · ", grey), r("acme/api", cyan)]]
        return l
    }
}

extension StreamClient {
    /// The demo Mac comes on screen: no connection, everything made up (PortholeDemo).
    func startDemo() {
        demo = true
        macName = PortholeDemo.macName
        windows = PortholeDemo.windows
        apps = PortholeDemo.apps
        displays = PortholeDemo.displays
        desktopDisplay = 1
        porthole.sessions = PortholeDemo.sessions
        porthole.browserTabs = PortholeDemo.tabs
        porthole.recentPicks = [1001, 1004, 1002, 1005]
        // Plain lettered icons: the demo shows nobody's artwork.
        let all = PortholeDemo.apps.map { ($0.bundleID, $0.name) } + PortholeFavourites.apps.map { ($0.bundleID, $0.name) }
        for (id, name) in all where icons[id] == nil { icons[id] = PortholeDemo.icon(name) }
        for w in PortholeDemo.windows {
            if let image = PortholeDemo.picture(for: .window(w.id)) {
                thumbnails[w.id] = image.preparingThumbnail(of: CGSize(width: 320, height: 200)) ?? image
            }
        }
        active = .window(1001)
        #if DEBUG
        InputScript.sessionListed(self)   // -PortholeInputScript in the demo (its clock starts here)
        #endif
    }

    func stopDemo() {
        guard demo else { return }
        demo = false
        windows = []
        apps = []
        displays = []
        porthole.sessions = []
        porthole.browserTabs = nil
        porthole.terminals = [:]
        porthole.terminalPanes = [:]
        porthole.recentPicks = []
        thumbnails = [:]
        icons = [:]
        active = .none
        macName = ""
    }
}
