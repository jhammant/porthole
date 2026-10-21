import AppKit
import CoreGraphics
import StreamProtocol

/// Porthole (docs/porthole-plan.md, Browser): Google Chrome's windows and tabs for the device's sidebar
/// (kind 208), and a tab brought forward on request (kind 209). Chrome is the browser most used alongside a Mac's terminals (3–17
/// Oct 2026). Read through AppleScript in PortholeOSAHelper, three bulk requests per window, and only while
/// Chrome runs (asking a stopped Chrome would launch it). Each Chrome window is matched to the window
/// server's window by its frame, so a tab's window can be streamed like any other.
enum PortholeBrowser {
    static let bundleID = "com.google.Chrome"

    struct Snapshot {
        let tabs: BrowserTabs
        /// Chrome's own window id for each window server id, for bringing a tab forward.
        let chromeIDs: [UInt32: String]
    }

    static func snapshot(_ osa: PortholeOSA) -> Snapshot? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return nil }
        guard let text = osa.call("chrometabs", []) else {
            print("Porthole: Chrome's tabs couldn't be read")
            return nil
        }
        return parse(text, windows: chromeWindowFrames())
    }

    /// Brings the tab forward in its window; the device then streams the window.
    static func activate(_ request: ActivateTab, in snapshot: Snapshot?, _ osa: PortholeOSA) -> Bool {
        guard let chromeID = snapshot?.chromeIDs[request.windowID] else { return false }
        return osa.call("activatetab", [chromeID, String(request.tabID)]) == "ok"
    }

    /// The window server's Chrome windows: id and frame (global points).
    static func chromeWindowFrames() -> [(id: UInt32, frame: CGRect)] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { w in
            guard (w[kCGWindowOwnerName as String] as? String) == "Google Chrome", (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? Int, let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: b as CFDictionary), frame.width > 100, frame.height > 100 else { return nil }
            return (UInt32(id), frame)
        }
    }

    /// The helper's lines ("W", chrome id, active index, left, top, right, bottom; "T", tab id, index,
    /// title, URL) → tabs, each window matched to a window server window by its frame (±3 pt). Pure, checked.
    static func parse(_ text: String, windows: [(id: UInt32, frame: CGRect)]) -> Snapshot {
        var out: [BrowserWindow] = []
        var chromeIDs: [UInt32: String] = [:]
        var current: (cg: UInt32, active: Int, tabs: [BrowserTab])?
        func close() {
            if let c = current { out.append(BrowserWindow(id: c.cg, tabs: c.tabs)) }
            current = nil
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if f.first == "W", f.count >= 7, let active = Int(f[2]),
               let l = Double(f[3]), let t = Double(f[4]), let r = Double(f[5]), let b = Double(f[6].trimmingCharacters(in: .whitespaces)) {
                close()
                let frame = CGRect(x: l, y: t, width: r - l, height: b - t)
                let match = windows.first { abs($0.frame.minX - frame.minX) <= 3 && abs($0.frame.minY - frame.minY) <= 3
                    && abs($0.frame.width - frame.width) <= 3 && abs($0.frame.height - frame.height) <= 3 }?.id ?? 0
                if match != 0 { chromeIDs[match] = f[1] }
                current = (match, active, [])
            } else if f.first == "T", f.count >= 5, let id = Int(f[1]), let index = Int(f[2]), current != nil {
                // A title can hold a tab character; the URL never does, so it is the last field.
                let title = f[3..<(f.count - 1)].joined(separator: "\t"), url = f[f.count - 1]
                current!.tabs.append(BrowserTab(id: id, title: title.isEmpty ? url : title, url: url, active: index == current!.active))
            }
        }
        close()
        return Snapshot(tabs: BrowserTabs(bundleID: bundleID, windows: out), chromeIDs: chromeIDs)
    }
}
