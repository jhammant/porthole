import Foundation
import StreamProtocol

/// Porthole (22 Oct, Jon: "a search on the claude code windows, and between them all"): words across every
/// listed Claude Code session's whole transcript (kind 214, answered with 215). grep finds where the words
/// are, whatever a file's size (some are tens of MB); each line they are on is then read as the transcript
/// reads it (PortholeTranscript): your prompts, Claude's words and its tool lines count; tool results,
/// thinking, side chains and bookkeeping don't. Newest first, in each session and across them.
enum PortholeSearch {
    struct Source {
        let sessionID: String
        let url: URL
    }

    /// Lines read in one session at most, newest first: a common word stops here rather than parse every
    /// line of a long session.
    static let linesPerSession = 600

    static func search(_ query: String, in sources: [Source]) -> [SessionSearchHits] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= PortholeWire.minSessionSearch, q.count <= PortholeWire.maxSearchQuery else { return [] }
        // Each session on its own core: one long transcript no longer holds up the rest (3.3 s for Jon's
        // sessions one after another, 22 Oct).
        var each = [SessionSearchHits?](repeating: nil, count: sources.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: sources.count) { i in
            let source = sources[i]
            guard let offsets = grep(q, in: source.url), !offsets.isEmpty,
                  let data = try? Data(contentsOf: source.url, options: .alwaysMapped),
                  let found = hits(q, in: data, at: offsets, sessionID: source.sessionID) else { return }
            lock.lock(); each[i] = found; lock.unlock()
        }
        return each.compactMap { $0 }.sorted { ($0.hits.first?.at ?? 0) > ($1.hits.first?.at ?? 0) }
    }

    /// One session's matches, from the lines at `offsets` (bytes into `data`), newest first.
    static func hits(_ q: String, in data: Data, at offsets: [Int], sessionID: String) -> SessionSearchHits? {
        var hits: [SessionSearchHit] = []
        var count = 0
        var seen = Set<Int>()
        for offset in offsets.reversed() where count < PortholeWire.searchMatchesPerSession && seen.count < linesPerSession {
            let line = lineBounds(data, around: offset)
            guard seen.insert(line.lowerBound).inserted else { continue }
            var transcript = PortholeTranscript(keep: 16)
            for entry in transcript.ingest(data.subdata(in: line)).reversed() {
                guard let s = snippet(entry.text, q) else { continue }
                count += 1
                if hits.count < PortholeWire.searchSnippetsPerSession { hits.append(SessionSearchHit(role: entry.role, snippet: s, at: entry.at)) }
            }
        }
        return count > 0 ? SessionSearchHits(sessionID: sessionID, count: count, hits: hits) : nil
    }

    /// Where `q` is in the file, ignoring case: byte offsets, from grep (fixed string, text even if a line
    /// looks binary, UTF-8 so case folds beyond ASCII). Nil when grep could not run.
    static func grep(_ q: String, in url: URL) -> [Int]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        p.arguments = ["-a", "-b", "-o", "-i", "-F", "--", q, url.path]
        p.environment = ["LC_ALL": "en_US.UTF-8"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus <= 1 else { return nil }   // 1: nothing found
        var offsets: [Int] = []
        for line in data.split(separator: 0x0A) {
            guard let colon = line.firstIndex(of: 0x3A), let n = Int(String(decoding: line[line.startIndex..<colon], as: UTF8.self)) else { continue }
            offsets.append(n)
        }
        return offsets
    }

    /// The line (without its newline) that the byte at `offset` is on.
    static func lineBounds(_ data: Data, around offset: Int) -> Range<Int> {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Range<Int> in
            let bytes = raw.bindMemory(to: UInt8.self)
            let at = min(max(0, offset), max(0, bytes.count - 1))
            var start = at, end = at
            while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
            while end < bytes.count, bytes[end] != 0x0A { end += 1 }
            return (data.startIndex + start)..<(data.startIndex + end)
        }
    }

    /// One line round the first place `q` is in `text`, ignoring case: nil when it isn't there.
    static func snippet(_ text: String, _ q: String, before: Int = 48, after: Int = 120) -> String? {
        let flat = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        guard let r = flat.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let start = flat.index(r.lowerBound, offsetBy: -before, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(r.upperBound, offsetBy: after, limitedBy: flat.endIndex) ?? flat.endIndex
        var s = String(flat[start..<end]).trimmingCharacters(in: .whitespaces)
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return (start > flat.startIndex ? "…" : "") + s + (end < flat.endIndex ? "…" : "")
    }
}
