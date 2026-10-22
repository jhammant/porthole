#!/usr/bin/env python3
r"""Porthole's judge for a text pane's history, its find, and the search across sessions (22 Oct), on the real
Claude Code sessions, read-only: a test host (PortholeHost --synthetic, no screen, 127.0.0.1 only, as
Scripts/porthole-e2e.py starts it) watches a session's terminal WITHOUT fitting it (nothing on the Mac is
resized), scrolls it, finds in it and searches across every session. Nothing is typed anywhere. Only counts
and yes/no go to the output, never a session's words.

usage: Scripts/porthole-e2e-history.py

Checks, each printed ok or FAIL; the exit status is the number of failures:
  history     a watched session says how many lines of history it has
  scroll      50 lines up comes back 50 lines up, its first line the line iTerm has there; 0 is live again
  find        words from the history are found: the newest match shown, on screen, and the one before it
  search      words from a session's last prompt find that session, with the words in the snippet
  nothing     a search for nonsense finds nothing
"""
import importlib.util
import json
import os
import struct
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("e2e", os.path.join(ROOT, "Scripts/porthole-e2e.py"))
e2e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e2e)
K_VIEW, K_SEARCH, K_RESULTS = 213, 214, 215
VENV = os.path.expanduser("~/Library/Application Support/Porthole/venv/bin/python")

class HistoryLink(e2e.Link):
    """A device's connection that files the session list, terminal screens and search results."""

    def read(self):
        buf = b""
        while True:
            try:
                chunk = self.s.recv(65536)
            except OSError:
                return
            if not chunk:
                return
            buf += chunk
            while len(buf) >= 14:
                kind, _, _, ln = struct.unpack(">BdBI", buf[:14])
                if len(buf) < 14 + ln:
                    break
                payload, buf = buf[14:14 + ln], buf[14 + ln:]
                if kind in (e2e.K_SESSIONS, e2e.K_SCREEN, K_RESULTS):
                    with self.lock:
                        self.got.append((kind, json.loads(payload)))
                        self.lock.notify_all()


def text(runs):
    return "".join(r.get("text", "") for r in runs)


def iterm_line(session, scrolled_up):
    """The line iTerm has `scrolled_up` lines above its live screen's first line, read on its own."""
    code = r'''
import sys, iterm2
async def main(c):
    app = await iterm2.async_get_app(c)
    s = app.get_session_by_id(sys.argv[1])
    async with iterm2.Transaction(c):
        li = await s.async_get_line_info()
        base = li.overflow + li.scrollback_buffer_height
        lines = await s.async_get_contents(base - int(sys.argv[2]), 1)
    print(lines[0].string.rstrip() if lines else "")
iterm2.run_until_complete(main)
'''
    return subprocess.run([VENV, "-I", "-c", code, session, str(scrolled_up)], capture_output=True, text=True, timeout=30).stdout.rstrip("\n")


def main():
    subprocess.run(["swift", "build", "-c", "release", "--product", "PortholeHost"], cwd=ROOT, check=True, capture_output=True)
    subprocess.run(["swift", "build", "-c", "release", "--product", "PortholeOSAHelper"], cwd=ROOT, check=True, capture_output=True)
    host, port = e2e.start_host()
    try:
        link = HistoryLink(port)
        sessions = link.wait(lambda k, b: k == e2e.K_SESSIONS, 30)
        sessions = (sessions or {}).get("sessions", [])
        withterm = [s for s in sessions if s.get("terminalID")]
        e2e.check("sessions", bool(withterm), f"{len(withterm)} sessions with a terminal")
        if not withterm:
            return

        # The session with the longest history that isn't busy rewriting its screen is best; take each in turn
        # until one has at least 120 lines of history.
        chosen, live = None, None
        for s in withterm:
            link.send(e2e.K_WATCH_TERM, {"terminalID": s["terminalID"], "windowID": s.get("windowID"), "colours": "dark"})
            screen = link.wait(lambda k, b: k == e2e.K_SCREEN and b["terminalID"] == s["terminalID"] and b.get("full"), 20)
            if screen and (screen.get("history") or 0) >= 120:
                chosen, live = s, screen
                break
        e2e.check("history", chosen is not None, f"{live.get('history') if live else 0} lines above the live screen")
        if not chosen:
            return
        tid = chosen["terminalID"]

        t0 = time.time()
        link.send(K_VIEW, {"terminalID": tid, "scrolledUp": 50})
        up = link.wait(lambda k, b: k == e2e.K_SCREEN and b["terminalID"] == tid and b.get("scrolledUp", 0) >= 50, 10)
        took = (time.time() - t0) * 1000
        first = text(up["lines"][0]["runs"]).rstrip() if up and up.get("lines") else None
        e2e.check("scroll", up is not None and up.get("scrolledUp") in (50, 51, 52) and first == iterm_line(tid, up.get("scrolledUp", 50)),
                  f"{up.get('scrolledUp') if up else '-'} lines up in {took:.0f} ms, the first line iTerm's" if up else "no screen")
        link.send(K_VIEW, {"terminalID": tid, "scrolledUp": 0})
        back = link.wait(lambda k, b: k == e2e.K_SCREEN and b["terminalID"] == tid and not b.get("scrolledUp"), 10)
        e2e.check("scroll back to live", back is not None)

        # A word of five or more letters from the scrolled screen: in the history for sure.
        words = [w.strip(".,:;()[]'\"`") for line in (up or {}).get("lines", []) for w in text(line["runs"]).split()]
        words = [w for w in words if len(w) >= 5 and w.isalpha()]
        if words:
            q = words[len(words) // 2]
            link.send(K_VIEW, {"terminalID": tid, "find": q, "step": 0})
            f = link.wait(lambda k, b: k == e2e.K_SCREEN and b["terminalID"] == tid and b.get("find") and b["find"]["query"] == q, 15)
            fi = (f or {}).get("find") or {}
            cur = [h for h in fi.get("hits", []) if h["current"]]
            row_text = ""
            if f and cur:
                byrow = {l["row"]: text(l["runs"]) for l in f.get("lines", [])}
                row_text = byrow.get(cur[0]["row"], "")
            e2e.check("find", fi.get("count", 0) >= 1 and fi.get("index") == fi.get("count") and len(cur) == 1 and q.lower() in row_text.lower(),
                      f"{fi.get('count', 0)} matches, showing {fi.get('index')}")
            if fi.get("count", 0) > 1:
                link.send(K_VIEW, {"terminalID": tid, "find": q, "step": -1})
                g = link.wait(lambda k, b: k == e2e.K_SCREEN and b["terminalID"] == tid and (b.get("find") or {}).get("index") == fi["count"] - 1, 10)
                e2e.check("find the one before", g is not None)
            link.send(K_VIEW, {"terminalID": tid, "endFind": True})
            h = link.wait(lambda k, b: k == e2e.K_SCREEN and b["terminalID"] == tid and not b.get("find"), 10)
            e2e.check("find ends", h is not None)
        else:
            e2e.check("find", False, "no word to look for")
        link.send(e2e.K_WATCH_TERM, {"terminalID": tid, "stop": True})

        # Search: words from a session's last prompt (its file read here, only to choose the words).
        picked = None
        for s in sessions:
            path = next((os.path.join(d, s["id"] + ".jsonl") for d in
                         [os.path.join(os.path.expanduser("~/.claude/projects"), x) for x in os.listdir(os.path.expanduser("~/.claude/projects"))]
                         if os.path.exists(os.path.join(d, s["id"] + ".jsonl"))), None)
            if not path:
                continue
            prompt = None
            with open(path, "rb") as fh:
                fh.seek(max(0, os.path.getsize(path) - 400_000))
                for raw in fh.read().split(b"\n"):
                    try:
                        r = json.loads(raw)
                    except Exception:
                        continue
                    m = r.get("message") or {}
                    if r.get("type") == "user" and isinstance(m.get("content"), str) and not r.get("isMeta") and not m["content"].startswith("<"):
                        prompt = m["content"]
            ws = [w for w in (prompt or "").split() if len(w) >= 6 and w.isalpha()]
            if ws:
                picked = (s["id"], ws[0])
                break
        if picked:
            t0 = time.time()
            link.send(K_SEARCH, {"id": 7, "query": picked[1]})
            res = link.wait(lambda k, b: k == K_RESULTS and b["id"] == 7, 30)
            took = (time.time() - t0) * 1000
            mine = next((x for x in (res or {}).get("sessions", []) if x["sessionID"] == picked[0]), None)
            e2e.check("search", mine is not None and mine["count"] >= 1 and any(picked[1].lower() in h["snippet"].lower() for h in mine["hits"]),
                      f"{len((res or {}).get('sessions', []))} sessions matched in {took:.0f} ms")
        else:
            e2e.check("search", False, "no prompt to take words from")
        link.send(K_SEARCH, {"id": 8, "query": "zq9xv qqjjxx nothing"})
        none = link.wait(lambda k, b: k == K_RESULTS and b["id"] == 8, 30)
        e2e.check("nothing", none is not None and none["sessions"] == [])
    finally:
        host.terminate()
        host.wait(timeout=10)
    print(f"porthole-e2e-history: {e2e.fails} failed" if e2e.fails else "porthole-e2e-history: all passed")
    sys.exit(e2e.fails)


if __name__ == "__main__":
    main()
