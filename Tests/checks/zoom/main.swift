// The Desktop's pinch zoom (PortholeZoom). Every check prints ok or FAIL; the exit status is the
// number of failures.
import CoreGraphics
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
var fails = 0
func check(_ name: String, _ ok: Bool) {
    if ok { print("ok   \(name)") } else { fails += 1; print("FAIL \(name)") }
}
func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.001 }
func near(_ a: CGPoint, _ b: CGPoint) -> Bool { near(a.x, b.x) && near(a.y, b.y) }

let panel = CGSize(width: 1000, height: 700)
let video = CGRect(x: 0, y: 68.75, width: 1000, height: 562.5)   // a 16:9 Desktop letterboxed in the panel

check("none draws the video where it is", PortholeZoom.none.apply(video) == video)

// A pinch spread to 2× about the panel's centre, fingers held still.
let centre = CGPoint(x: 500, y: 350)
let z = PortholeZoom.pinched(from: .none, at: centre, scale: 2, to: centre, in: panel)
check("2× about the centre", near(z.scale, 2) && near(z.offset.width, -500) && near(z.offset.height, -350))
// The point that was under the fingers is drawn under them still: p × scale + offset.
check("the point under the fingers stays", near(CGPoint(x: centre.x * z.scale + z.offset.width, y: centre.y * z.scale + z.offset.height), centre))

// Touch mapping: the drawn rect and the mapped rect are one, so a tap at the panel's centre is the
// Desktop's centre at any zoom about it.
let drawn = z.apply(video)
let fx = (centre.x - drawn.minX) / drawn.width, fy = (centre.y - drawn.minY) / drawn.height
check("a tap at the centre is the Desktop's centre", near(fx, 0.5) && near(fy, 0.5))

// Zoomed about a corner: the corner stays put, nothing shows past the edge.
let corner = PortholeZoom.pinched(from: .none, at: .zero, scale: 3, to: .zero, in: panel)
check("about the top-left corner", near(corner.offset.width, 0) && near(corner.offset.height, 0) && near(corner.scale, 3))

// Moving both fingers pans; past the edge it stops at the edge.
let panned = PortholeZoom.pinched(from: .none, at: centre, scale: 2, to: CGPoint(x: 600, y: 350), in: panel)
check("moving the fingers pans", near(panned.offset.width, -400))
let tooFar = PortholeZoom.panned(from: z, by: CGPoint(x: 5000, y: -5000), in: panel)
check("never off the left or bottom edge", near(tooFar.offset.width, 0) && near(tooFar.offset.height, 700 - 1400))

// Limits.
check("never below 1×: back to none", PortholeZoom.pinched(from: z, at: centre, scale: 0.2, to: centre, in: panel) == .none)
check("never past 5×", near(PortholeZoom.pinched(from: z, at: centre, scale: 10, to: centre, in: panel).scale, PortholeZoom.maxScale))
check("isZoomed", z.isZoomed && !PortholeZoom.none.isZoomed)

// A second pinch starts from the first's zoom: 2× then 1.5× is 3× with the fingers' point kept.
let second = PortholeZoom.pinched(from: z, at: CGPoint(x: 300, y: 200), scale: 1.5, to: CGPoint(x: 300, y: 200), in: panel)
let q = CGPoint(x: (300 - z.offset.width) / z.scale, y: (200 - z.offset.height) / z.scale)
check("a second pinch compounds and keeps its point", near(second.scale, 3)
      && near(CGPoint(x: q.x * second.scale + second.offset.width, y: q.y * second.scale + second.offset.height), CGPoint(x: 300, y: 200)))

print(fails == 0 ? "all zoom checks passed" : "\(fails) zoom check(s) failed")
exit(Int32(fails))
