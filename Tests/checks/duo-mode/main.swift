// The Duo's laptop or whole screen (PortholeDuoMode). Every check prints ok or FAIL; the exit status is
// the number of failures.
import Foundation
import CoreGraphics

setvbuf(stdout, nil, _IOLBF, 0)
var fails = 0
func check(_ name: String, _ ok: Bool) {
    if ok { print("ok   \(name)") } else { fails += 1; print("FAIL \(name)") }
}

let upright = CGSize(width: 669, height: 951), sideways = CGSize(width: 951, height: 669)
func pose(_ hinge: DuoPosture.Hinge, _ size: CGSize) -> DuoPosture.Pose { DuoPosture(hinge: hinge).pose(size) }
let d = (half: PortholeDuoMode.halfFoldedDefault, flat: PortholeDuoMode.flatDefault)

check("half-folded upright is the laptop", PortholeDuoMode.upright(pose(.partiallyOpen, upright), halfFolded: d.half, flat: d.flat) == .laptop)
check("open flat upright is the whole screen", PortholeDuoMode.wholeScreen(pose(.fullyOpen, upright), halfFolded: d.half, flat: d.flat))
check("the laptop pose is never the whole screen by default", !PortholeDuoMode.wholeScreen(pose(.partiallyOpen, upright), halfFolded: d.half, flat: d.flat))
check("the settings swap them", PortholeDuoMode.wholeScreen(pose(.partiallyOpen, upright), halfFolded: .wholeScreen, flat: .laptop)
      && !PortholeDuoMode.wholeScreen(pose(.fullyOpen, upright), halfFolded: .wholeScreen, flat: .laptop))
check("sideways keeps its own layout", PortholeDuoMode.upright(pose(.partiallyOpen, sideways), halfFolded: .wholeScreen, flat: .wholeScreen) == nil
      && PortholeDuoMode.upright(pose(.fullyOpen, sideways), halfFolded: .wholeScreen, flat: .wholeScreen) == nil)
check("the cover and no hinge keep theirs", PortholeDuoMode.upright(pose(.closed, upright), halfFolded: .wholeScreen, flat: .wholeScreen) == nil
      && PortholeDuoMode.upright(pose(.unknown, upright), halfFolded: .wholeScreen, flat: .wholeScreen) == nil)
check("the book's fold divides the sidebar", PortholeDuoMode.foldDivides(pose(.partiallyOpen, sideways)))
check("open flat sideways it does not", !PortholeDuoMode.foldDivides(pose(.fullyOpen, sideways)))
check("the saved words are the cases'", PortholeDuoMode(rawValue: "wholeScreen") == .wholeScreen && PortholeDuoMode(rawValue: "laptop") == .laptop)

print(fails == 0 ? "duo-mode: all passed" : "duo-mode: \(fails) failed")
exit(Int32(fails))
