#!/usr/bin/env python3
r"""Porthole's tiles judge (docs/porthole-plan.md, Judges): a real host on this Mac tiles scratch windows.

usage: Scripts/porthole-tiles-test.py

Opens four scratch iTerm2 windows (plain shells, never Jon's), starts Porthole's test host on 127.0.0.1 only
(synthetic, not advertised), and as a device: two tiles, then four, then none. Checks, ok or FAIL, exit
status the number of failures:
  two         the two windows sit side by side on the tiles display, each about half its width, and
              video frames arrive
  four        the four windows sit in a 2x2 grid, and frames arrive
  home        with tiles off, every window is back exactly where it was
"""
import json, os, re, socket, struct, subprocess, sys, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
fails = 0


def check(name, ok, detail=""):
    global fails
    fails += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} {name}{(': ' + detail) if detail else ''}", flush=True)


def osa(script):
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=20).stdout.strip()


def bounds(wid):
    """A window's frame from the window server, (x, y, w, h) in global points."""
    out = subprocess.run(["swift", "-e", f"""
import CoreGraphics
let l = CGWindowListCopyWindowInfo([.optionIncludingWindow], {wid}) as? [[String: Any]] ?? []
if let b = l.first?[kCGWindowBounds as String] as? [String: Double] {{ print(Int(b["X"]!), Int(b["Y"]!), Int(b["Width"]!), Int(b["Height"]!)) }}
"""], capture_output=True, text=True, timeout=60).stdout.split()
    return tuple(int(v) for v in out) if len(out) == 4 else None


def frame(kind, body):
    p = json.dumps(body).encode()
    return struct.pack(">BdBI", kind, time.time(), 0, len(p)) + p


class Link:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=10)
        self.s.settimeout(None)
        self.frames = 0
        self.lists = []
        threading.Thread(target=self.read, daemon=True).start()
        self.s.sendall(frame(23, {"appVersion": "porthole-tiles", "build": "1", "protocol": 1, "device": "porthole-tiles"}))

    def read(self):
        buf = b""
        while True:
            try:
                c = self.s.recv(1 << 20)
            except OSError:
                return
            if not c:
                return
            buf += c
            while len(buf) >= 14:
                kind, _, _, ln = struct.unpack(">BdBI", buf[:14])
                if len(buf) < 14 + ln:
                    break
                payload, buf = buf[14:14 + ln], buf[14 + ln:]
                if kind == 1:
                    self.frames += 1
                elif kind == 2:
                    self.lists.append(json.loads(payload))


def main():
    subprocess.run(["swift", "build", "-c", "release", "--product", "PortholeHost"], cwd=ROOT, check=True, capture_output=True)
    wids = [osa('tell application "iTerm2" to id of (create window with default profile)') for _ in range(4)]
    time.sleep(2)
    home = {w: bounds(w) for w in wids}
    print("scratch windows:", ", ".join(f"{w} at {home[w]}" for w in wids))
    log = open(os.path.join(ROOT, ".build/porthole-tiles-host.log"), "w")
    host = subprocess.Popen([os.path.join(ROOT, ".build/release/PortholeHost"), "--synthetic"], cwd=ROOT, stdin=subprocess.DEVNULL,
                            env=dict(os.environ, PORTHOLE_TEST_LOOPBACK="1"), stdout=log, stderr=subprocess.STDOUT)
    try:
        port = None
        for _ in range(80):
            time.sleep(0.25)
            out = subprocess.run(["lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", str(host.pid)], capture_output=True, text=True).stdout
            m = re.findall(r"127\.0\.0\.1:(\d+)", out)
            if m:
                port = int(m[0]); break
        assert port, "no test host"
        link = Link(port)
        time.sleep(2)
        link.s.sendall(frame(9, {"width": 1366, "height": 1000, "scale": 2, "fps": 30}))
        # Where each window really is now: a new iTerm window can still be settling when first read.
        now = {w: bounds(w) for w in wids}
        moved_meanwhile = [w for w in wids if now[w] != home[w]]
        if moved_meanwhile:
            print("     settled since first read:", ", ".join(f"{w} {home[w]} -> {now[w]}" for w in moved_meanwhile))
        home.update(now)

        def tiles(ids, label, cols):
            start = link.frames
            link.s.sendall(frame(6, {"tiles": {"_0": [int(w) for w in ids]}}))
            time.sleep(6)
            got = {w: bounds(w) for w in ids}
            widths = [b[2] for b in got.values() if b]
            moved = all(got[w] and got[w] != home[w] for w in ids)
            # A terminal keeps whole character cells, so it may take a little less than its tile.
            half = all(0.8 * 1366 / cols <= wd <= 1366 / cols + 4 for wd in widths)
            xs = sorted(set(b[0] for b in got.values() if b))
            check(label, moved and half and link.frames - start > 10 and len(xs) == cols,
                  f"moved: {moved}, widths {widths} (want ~{1366 // cols}), columns {len(xs)}, frames {link.frames - start}")

        tiles(wids[:2], "two", 2)
        tiles(wids, "four", 2)
        link.s.sendall(frame(6, {"none": {}}))
        time.sleep(4)
        back = {w: bounds(w) for w in wids}
        off = [w for w in wids if not back[w] or any(abs(a - b) > 2 for a, b in zip(back[w], home[w]))]
        check("home", not off, "every window where it was" if not off else f"not back: {[(w, home[w], back[w]) for w in off]}")
    finally:
        host.terminate()
        try: host.wait(timeout=10)
        except Exception: host.kill()
        for w in wids:
            osa(f'tell application "iTerm2" to close (first window whose id is {w})')
    print("all checks passed" if fails == 0 else f"{fails} check(s) failed")
    sys.exit(fails)


main()
