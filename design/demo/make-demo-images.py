#!/usr/bin/env python3
"""The demo Mac's window pictures (iOSClient/PortholeDemo.swift): made-up windows drawn with Pillow, so the
demo, App Review and the store's screenshots show nobody's real work.

usage: design/demo/make-demo-images.py      writes iOSClient/demo-*.png
"""
import pathlib
from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "iOSClient"
W, H = 2400, 1500
HACK = str(ROOT / "iOSClient/HackNerdFontMono-Regular.ttf")
HACK_BOLD = str(ROOT / "iOSClient/HackNerdFontMono-Bold.ttf")
SANS = "/System/Library/Fonts/Helvetica.ttc"

SOL = dict(bg=(0, 43, 54), fg=(131, 148, 150), white=(238, 232, 213), grey=(88, 110, 117), green=(133, 153, 0),
           blue=(38, 139, 210), yellow=(181, 137, 0), orange=(215, 119, 87), cyan=(42, 161, 152), violet=(108, 113, 196))


def font(path, size, index=0):
    return ImageFont.truetype(path, size, index=index)


def window(title, body_bg, dark=True):
    im = Image.new("RGB", (W, H), body_bg)
    d = ImageDraw.Draw(im)
    bar = (40, 42, 46) if dark else (236, 236, 236)
    d.rectangle([0, 0, W, 76], fill=bar)
    for i, c in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
        d.ellipse([30 + i * 44, 24, 58 + i * 44, 52], fill=c)
    f = font(SANS, 30)
    tw = d.textlength(title, font=f)
    d.text(((W - tw) / 2, 20), title, font=f, fill=(200, 200, 200) if dark else (60, 60, 60))
    return im, d


def terminal(name, title, lines):
    im, d = window(title, SOL["bg"])
    reg, bold = font(HACK, 34), font(HACK_BOLD, 34)
    y = 110
    for line in lines:
        x = 40
        for text, colour, is_bold, *bg in line:
            f = bold if is_bold else reg
            w = d.textlength(text, font=f)
            if bg:
                d.rectangle([x - 2, y + 2, x + w + 2, y + 44], fill=SOL[bg[0]])
            d.text((x, y), text, font=f, fill=SOL[colour])
            x += w
        y += 50
    im.save(OUT / f"{name}.png", optimize=True)


def t(text, colour="fg", bold=False, bg=None):
    return (text, colour, bold, bg) if bg else (text, colour, bold)


RULE = [t("─" * 104, "grey")]
COMMON = [
    [t("> ", "grey"), t("Add rate limiting to the public API: 100 requests a minute per client.", "white")],
    [],
    [t("● ", "white"), t("I'll add a token-bucket limiter as middleware and wire it into the router.")],
    [],
    [t("● ", "green"), t("Read", "white", True), t("(src/server/router.ts)")],
    [t("  └  ", "grey"), t("Read 142 lines", "grey")],
    [],
    [t("● ", "green"), t("Write", "white", True), t("(src/middleware/rateLimit.ts)")],
    [t("  └  ", "grey"), t("Wrote 48 lines to src/middleware/rateLimit.ts", "grey")],
    [],
    [t("● ", "green"), t("Bash", "white", True), t("(npm test -- rateLimit)")],
    [t("  └  ", "grey"), t(" PASS ", "bg", True, "green"), t("  test/rateLimit.test.ts (6 tests, 0.42 s)")],
    [],
]
terminal("demo-terminal", "acme · add rate limiting — claude", COMMON + [
    [t("● ", "white"), t("The limiter is in and its tests pass. One choice before I finish:")],
    [],
    [t("  Should the limit apply per user or per API key?", "white", True)],
    [],
    [t("  ❯ 1. ", "blue"), t("Per API key", "blue", True), t("  (a user's scripts share their key)", "grey")],
    [t("    2. Per user")],
    [t("    3. Both, whichever is hit first")],
    [],
    RULE, [t("❯ ", "white")], RULE,
    [t("  ▸▸ accept edits on", "violet"), t(" · ", "grey"), t("acme/api", "cyan")],
])
terminal("demo-terminal-2", "acme · fix flaky test — claude", [
    [t("> ", "grey"), t("test/checkout.test.ts fails about one run in ten. Find out why and fix it.", "white")],
    [],
    [t("● ", "white"), t("I'll run it repeatedly to see the failure, then look at what it shares.")],
    [],
    [t("● ", "green"), t("Bash", "white", True), t("(for i in $(seq 20); do npm test -- checkout || break; done)")],
    [t("  └  ", "grey"), t(" FAIL ", "bg", True, "orange"), t("  run 7: expected 2 items, received 3")],
    [],
    [t("● ", "white"), t("The cart fixture is shared between tests and one test adds to it without")],
    [t("  resetting. I'll give each test its own cart.")],
    [],
    [t("● ", "green"), t("Update", "white", True), t("(test/checkout.test.ts)")],
    [t("  └  ", "grey"), t("Updated with 6 additions and 2 removals", "grey")],
    [],
    [t("✻ ", "orange"), t("Running the suite 20 times… ", "orange"), t("(1m 12s · esc to interrupt)", "grey")],
    [],
    RULE, [t("❯ ", "white")], RULE,
    [t("  ▸▸ accept edits on", "violet"), t(" · ", "grey"), t("acme/api", "cyan")],
])

# A pull request in a browser.
im, d = window("Add rate limiting to the public API #42 · acme/api", (255, 255, 255), dark=False)
d.rectangle([0, 76, W, 170], fill=(246, 248, 250))
f = font(SANS, 30)
d.rounded_rectangle([40, 96, 1500, 150], radius=26, fill=(255, 255, 255), outline=(208, 215, 222), width=2)
d.text((76, 106), "github.com/acme/api/pull/42", font=f, fill=(87, 96, 106))
d.text((80, 230), "Add rate limiting to the public API", font=font(SANS, 64), fill=(31, 35, 40))
d.text((1300, 238), "#42", font=font(SANS, 64), fill=(101, 109, 118))
d.rounded_rectangle([80, 330, 270, 388], radius=29, fill=(31, 136, 61))
d.text((122, 340), "Open", font=font(SANS, 34), fill=(255, 255, 255))
d.text((300, 342), "acme-bot wants to merge 3 commits into main from rate-limit", font=f, fill=(87, 96, 106))
d.line([80, 430, W - 80, 430], fill=(208, 215, 222), width=2)
d.rounded_rectangle([80, 470, W - 80, 540], radius=12, fill=(246, 248, 250), outline=(208, 215, 222), width=2)
d.text((110, 486), "src/middleware/rateLimit.ts", font=font(HACK, 30), fill=(31, 35, 40))
d.text((W - 300, 486), "+48 −0", font=font(HACK, 30), fill=(26, 127, 55))
code = ["export function rateLimit(perMinute = 100) {", "  const buckets = new Map<string, Bucket>()",
        "  return (req, res, next) => {", "    const key = req.apiKey ?? req.ip", "    const bucket = take(buckets, key, perMinute)",
        "    if (bucket.empty) return res.status(429).send(retryAfter(bucket))", "    next()", "  }", "}"]
y = 560
for i, line in enumerate(code):
    d.rectangle([80, y, W - 80, y + 54], fill=(230, 255, 236))
    d.text((100, y + 10), f"{i + 1:>3}  + {line}", font=font(HACK, 30), fill=(31, 35, 40))
    y += 54
d.rounded_rectangle([80, y + 40, 520, y + 110], radius=12, fill=(31, 136, 61))
d.text((120, y + 56), "Merge pull request", font=font(SANS, 34), fill=(255, 255, 255))
im.save(OUT / "demo-browser.png", optimize=True)

# Another app: a chat channel.
im, d = window("#eng — Acme", (255, 255, 255), dark=False)
d.rectangle([0, 76, 520, H], fill=(63, 14, 64))
for i, ch in enumerate(["# general", "# eng", "# releases", "# random"]):
    if ch == "# eng":
        d.rectangle([0, 180 + i * 70, 520, 240 + i * 70], fill=(18, 100, 163))
    d.text((50, 190 + i * 70), ch, font=font(SANS, 34), fill=(255, 255, 255))
msgs = [("Sam", "Is the rate limiter going out today?"), ("Priya", "PR #42 is up, tests pass. Waiting on one decision."),
        ("Sam", "Per API key makes sense to me."), ("Priya", "Agreed. Merging after lunch.")]
for i, (who, text) in enumerate(msgs):
    y = 140 + i * 170
    d.rounded_rectangle([580, y, 660, y + 80], radius=14, fill=[(234, 120, 70), (60, 140, 220)][i % 2])
    d.text((690, y), who, font=font(SANS, 36), fill=(29, 28, 29))
    d.text((690, y + 50), text, font=font(SANS, 34), fill=(60, 60, 60))
im.save(OUT / "demo-app.png", optimize=True)

# The desktop: a wallpaper, the menu bar, two windows and the Dock.
im = Image.new("RGB", (W, H))
d = ImageDraw.Draw(im)
for y in range(H):
    k = y / H
    d.line([0, y, W, y], fill=(int(30 + 60 * k), int(40 + 30 * k), int(90 + 80 * k)))
d.rectangle([0, 0, W, 48], fill=(30, 30, 34))
d.text((40, 8), "  Porthole Demo   File   Edit   View   Window", font=font(SANS, 28), fill=(235, 235, 235))
term = Image.open(OUT / "demo-terminal.png").resize((1300, 812))
web = Image.open(OUT / "demo-browser.png").resize((1100, 688))
im.paste(web, (1180, 160))
im.paste(term, (120, 420))
d.rounded_rectangle([700, H - 130, 1700, H - 20], radius=28, fill=(255, 255, 255, 60), outline=(200, 200, 220), width=2)
for i, c in enumerate([(66, 133, 244), (40, 40, 40), (52, 199, 89), (255, 149, 0), (88, 86, 214), (255, 59, 48)]):
    d.rounded_rectangle([740 + i * 160, H - 115, 840 + i * 160, H - 35], radius=20, fill=c)
im.save(OUT / "demo-desktop.png", optimize=True)
print("wrote", ", ".join(p.name for p in sorted(OUT.glob("demo-*.png"))))
