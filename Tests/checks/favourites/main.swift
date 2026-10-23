// Jon's favourite apps (PortholeFavouritesList). Every check prints ok or FAIL; the exit status is the
// number of failures.
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
var fails = 0
func check(_ name: String, _ ok: Bool) {
    if ok { print("ok   \(name)") } else { fails += 1; print("FAIL \(name)") }
}

var l = PortholeFavouritesList.standard
check("the first list is the standard seven", l.apps.map(\.key) == ["c", "l", "w", "k", "m", "a", "f"])
check("no free key is reserved or taken", l.freeKeys().allSatisfy { !"sbvtgjdclwkmaf".contains($0) })
l.add(bundleID: "com.googlecode.iterm2", name: "iTerm2")
check("an app takes the first free letter of its name", l.apps.last?.key == "i")
l.add(bundleID: "com.apple.Safari", name: "Safari")
check("a name's reserved letter is skipped (S is the sidebar)", l.apps.last?.key == "r")
l.add(bundleID: "com.apple.Safari", name: "Safari")
check("adding twice adds once", l.apps.filter { $0.bundleID == "com.apple.Safari" }.count == 1)
l.move("com.apple.Safari", by: -1)
check("move up", l.apps[l.apps.count - 2].bundleID == "com.apple.Safari")
l.move("com.google.Chrome", by: -1)
check("nothing past the top", l.apps.first?.bundleID == "com.google.Chrome")
l.setKey("com.apple.Safari", to: "c")
check("a taken letter swaps", l.app(forKey: "c")?.bundleID == "com.apple.Safari" && l.app(forKey: "r")?.bundleID == "com.google.Chrome")
l.setKey("com.apple.Safari", to: "s")
check("a reserved letter is refused", l.app(forKey: "c")?.bundleID == "com.apple.Safari")
l.setKey("com.apple.Safari", to: nil)
check("no key", l.apps.first { $0.bundleID == "com.apple.Safari" }?.key == "" && l.app(forKey: "c") == nil)
l.remove("com.apple.Safari")
check("removed", !l.contains("com.apple.Safari"))
check("a key finds its app, case aside", l.app(forKey: "I")?.bundleID == "com.googlecode.iterm2")
var old = PortholeFavouritesList(apps: [.init(bundleID: "com.hnc.Discord", name: "Discord", key: "d")])
check("a letter Porthole took later (D, the Desktop) finds no favourite", old.app(forKey: "d") == nil)
old = old.withoutReservedKeys()
check("and the favourite loses it", old.apps.first?.key == "")
var discord = PortholeFavouritesList(apps: [])
discord.add(bundleID: "com.hnc.Discord", name: "Discord")
check("a new favourite skips D", discord.apps.first?.key == "i")
let data = try! JSONEncoder().encode(l)
check("kept and read back the same", (try? JSONDecoder().decode(PortholeFavouritesList.self, from: data)) == l)

print(fails == 0 ? "all favourites checks passed" : "\(fails) favourites check(s) failed")
exit(Int32(fails))
