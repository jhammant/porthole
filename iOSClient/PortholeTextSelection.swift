import Foundation

/// Porthole (31 Oct, "I can't do multi line copy"): the text between two cells of a session's screen, in
/// reading order, as the text pane's selection copies it (pure, checked: Tests/checks/text-selection).
enum PortholeTextSelection {
    struct Cell: Equatable { var row: Int; var column: Int }

    static func ordered(_ a: Cell, _ b: Cell) -> (Cell, Cell) {
        (a.row, a.column) <= (b.row, b.column) ? (a, b) : (b, a)
    }

    /// The rows' text from one cell to the other, both included, each line without its trailing spaces. A
    /// wide character (CJK, most emoji) takes two columns, as the pane draws it.
    static func text(_ lines: [String], from: Cell, to: Cell, wide: (Character) -> Bool = { _ in false }) -> String {
        let (a, b) = ordered(from, to)
        let lo = max(a.row, 0), hi = min(b.row, lines.count - 1)
        guard lo <= hi else { return "" }
        return (lo...hi).map { row in
            slice(lines[row], from: row == a.row ? a.column : 0, through: row == b.row ? b.column : Int.max, wide: wide)
                .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }.joined(separator: "\n")
    }

    /// The characters of a line whose columns fall within start...end.
    static func slice(_ line: String, from start: Int, through end: Int, wide: (Character) -> Bool) -> String {
        var column = 0, out = ""
        for c in line {
            let width = wide(c) ? 2 : 1
            if column + width - 1 >= start, column <= end { out.append(c) }
            column += width
            if column > end { break }
        }
        return out
    }
}
