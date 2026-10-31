// The text pane's selection (31 Oct, "I can't do multi line copy").
import Foundation

var fails = 0, passes = 0
func check(_ name: String, _ ok: Bool) {
    if ok { passes += 1 } else { fails += 1; print("FAIL \(name)") }
}
typealias C = PortholeTextSelection.Cell
let screen = ["$ ls -la   ", "total 12   ", "drwxr-xr-x  docs", "-rw-r--r--  README.md", ""]

check("one whole line", PortholeTextSelection.text(screen, from: C(row: 1, column: 0), to: C(row: 1, column: .max)) == "total 12")
check("across lines, partial ends", PortholeTextSelection.text(screen, from: C(row: 0, column: 2), to: C(row: 2, column: 9)) == "ls -la\ntotal 12\ndrwxr-xr-x")
check("dragged upwards reads the same", PortholeTextSelection.text(screen, from: C(row: 2, column: 9), to: C(row: 0, column: 2))
      == PortholeTextSelection.text(screen, from: C(row: 0, column: 2), to: C(row: 2, column: 9)))
check("same row backwards", PortholeTextSelection.text(screen, from: C(row: 3, column: 21), to: C(row: 3, column: 12)) == "README.md")
check("past the last row stops at it", PortholeTextSelection.text(screen, from: C(row: 3, column: 0), to: C(row: 40, column: 3)) == "-rw-r--r--  README.md\n")
check("past the line's end is the line", PortholeTextSelection.text(screen, from: C(row: 2, column: 12), to: C(row: 2, column: 300)) == "docs")
check("nothing on an empty screen", PortholeTextSelection.text([], from: C(row: 0, column: 0), to: C(row: 3, column: 3)) == "")
let wide: (Character) -> Bool = { $0 == "日" || $0 == "本" }
check("wide characters take two columns", PortholeTextSelection.text(["日本 ok"], from: C(row: 0, column: 2), to: C(row: 0, column: 3), wide: wide) == "本")
check("a wide character half selected is taken whole", PortholeTextSelection.text(["日本 ok"], from: C(row: 0, column: 1), to: C(row: 0, column: 1), wide: wide) == "日")
check("after wide characters the columns line up", PortholeTextSelection.text(["日本 ok"], from: C(row: 0, column: 5), to: C(row: 0, column: 6), wide: wide) == "ok")

print("text-selection: \(passes) checks, \(fails) failed")
exit(Int32(fails))
