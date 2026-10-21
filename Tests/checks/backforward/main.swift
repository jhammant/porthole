// Back and forward (PortholeBackForward). Every check prints ok or FAIL; the exit status is the number
// of failures.
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
var fails = 0
func check(_ name: String, _ ok: Bool) {
    if ok { print("ok   \(name)") } else { fails += 1; print("FAIL \(name)") }
}
let open: (String) -> Bool = { _ in true }

var h = PortholeBackForward<String>()
check("nothing to go back to at first", h.step(-1, isOpen: open) == nil)
for s in ["a", "b", "c"] { h.visit(s) }
check("back goes to the one before", h.step(-1, isOpen: open) == "b")
h.visit("b")   // opening it (as back does) changes nothing
check("back again", h.step(-1, isOpen: open) == "a")
check("no further back", h.step(-1, isOpen: open) == nil)
check("forward", h.step(1, isOpen: open) == "b")
check("forward again", h.step(1, isOpen: open) == "c")
check("no further forward", h.step(1, isOpen: open) == nil)
_ = h.step(-1, isOpen: open)                 // at b
h.visit("d")                                 // something new: c, ahead, goes
check("a new visit drops what was ahead", h.items == ["a", "b", "d"] && h.step(1, isOpen: open) == nil)
check("back from the new one", h.step(-1, isOpen: open) == "b")
_ = h.step(1, isOpen: open)                  // at d
check("gone ones are skipped", h.step(-1, isOpen: { $0 != "b" }) == "a")
var full = PortholeBackForward<Int>()
for i in 0..<60 { full.visit(i) }
check("kept to the limit, newest last", full.items.count == PortholeBackForward<Int>.limit && full.items.last == 59)
var same = PortholeBackForward<String>()
same.visit("x"); same.visit("x")
check("the same twice is one", same.items == ["x"])

print(fails == 0 ? "all back/forward checks passed" : "\(fails) back/forward check(s) failed")
exit(Int32(fails))
