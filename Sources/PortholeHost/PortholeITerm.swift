import Foundation
import StreamProtocol

/// Porthole (docs/porthole-plan.md, Replies): typing into an iTerm2 session, found by its unique id,
/// through AppleScript. The text goes to osascript as an argument, never spliced into the script, so
/// nothing in it can change what the script does.
enum PortholeITerm {
    /// The bytes a reply sends: one line as typed; several lines as a bracketed paste, so a newline
    /// never submits early (Claude Code takes the paste whole); then Return.
    static func bytes(forReply text: String) -> (body: String, submit: Bool) {
        if text.contains("\n") { return ("\u{1B}[200~" + text + "\u{1B}[201~", true) }
        return (text, true)
    }

    /// The bytes a key sends, as a terminal would.
    static func bytes(for key: SessionReply.Key) -> String {
        switch key {
        case .esc: return "\u{1B}"
        case .enter: return "\r"
        case .up: return "\u{1B}[A"
        case .down: return "\u{1B}[B"
        case .option1: return "1"
        case .option2: return "2"
        case .option3: return "3"
        case .option4: return "4"
        case .option5: return "5"
        case .option6: return "6"
        case .option7: return "7"
        case .option8: return "8"
        case .option9: return "9"
        }
    }

    /// Writes `body` to the session, then Return if `submit`. Nil when done, else why not.
    static func write(_ body: String, submit: Bool, toSession uniqueID: String) -> String? {
        let script = """
        on run argv
            set uid to item 1 of argv
            set body to item 2 of argv
            set submit to item 3 of argv
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if unique id of s is uid then
                                if body is not "" then tell s to write text body newline no
                                if submit is "1" then
                                    delay 0.15
                                    tell s to write text (ASCII character 13) newline no
                                end if
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "missing"
        end run
        """
        guard let out = PortholeSessions.run("/usr/bin/osascript", ["-e", script, uniqueID, body, submit ? "1" : "0"], timeout: 8),
              let answer = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return "iTerm didn’t answer."
        }
        return answer == "ok" ? nil : "That terminal has closed."
    }
}
