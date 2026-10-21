#!/usr/bin/env python3
r"""Porthole's end-to-end judge (docs/porthole-plan.md, Judges): a real host on this Mac and the real
Claude Code sessions, checked from the outside the way a device sees them.

usage: Scripts/porthole-e2e.py [--port PORT] [--no-reply]

  With no --port it starts .build/release/PortholeHost --synthetic with PORTHOLE_TEST_LOOPBACK=1: Porthole's test
  host, which never advertises, streams only a test pattern, posts no input and, with that variable,
  listens on 127.0.0.1 alone. It finds the port with lsof and stops the host at the end.

  --no-reply  skip the reply checks. Without it, the script opens a scratch Claude Code session (Haiku,
              in ~/dev) in a new iTerm window, replies to it through the host, and closes it after.

Checks, each printed ok or FAIL; the exit status is the number of failures:
  sessions    the session list (kind 200) names exactly the sessions `claude agents --json` names
  names       a session given a name is listed by it (as `claude agents` shows it), not by its ai-title
  transcript  a session's transcript (kind 202) matches its file: consecutive sequence numbers, at
              most 200 entries, and the last entry is the file's last prompt or Claude text
  reply       a one-line reply is typed and submitted: it shows up as your prompt, and Claude answers
  multiline   a two-line reply arrives as one prompt (a bracketed paste), control characters removed
  ratelimit   more than 4 replies in a second: the extra ones are refused
  unknown     a reply to a session that does not exist is refused, with a reason
"""
import json
import os
import re
import socket
import struct
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLAUDE = os.path.expanduser("~/.local/bin/claude")
K_SESSIONS, K_WATCH, K_TRANSCRIPT, K_REPLY, K_RESULT = 200, 201, 202, 203, 204
K_WATCH_TERM, K_SCREEN, K_TERM_INPUT = 205, 206, 207
K_TABS, K_ACTIVATE_TAB = 208, 209
fails = 0


def check(name, ok, detail=""):
    global fails
    if not ok:
        fails += 1
    print(f"{'ok  ' if ok else 'FAIL'} {name}{(': ' + detail) if detail else ''}", flush=True)


def frame(kind, body):
    payload = json.dumps(body).encode()
    return struct.pack(">BdBI", kind, time.time(), 0, len(payload)) + payload


class Link:
    """A device's connection: a reader thread files every message by kind."""

    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=10)
        self.s.settimeout(None)
        self.lock = threading.Condition()
        self.got = []          # (kind, json) in arrival order
        threading.Thread(target=self.read, daemon=True).start()
        self.send(23, {"appVersion": "porthole-e2e", "build": "1", "protocol": 1, "device": "porthole-e2e"})

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
                if kind in (K_SESSIONS, K_TRANSCRIPT, K_RESULT, K_SCREEN, K_TABS):
                    with self.lock:
                        self.got.append((kind, json.loads(payload)))
                        self.lock.notify_all()

    def send(self, kind, body):
        self.s.sendall(frame(kind, body))

    def wait(self, test, timeout):
        """The first message since `start` that passes test(kind, body), or None after timeout."""
        deadline = time.time() + timeout
        with self.lock:
            seen = 0
            while True:
                for kind, body in self.got[seen:]:
                    if test(kind, body):
                        return body
                seen = len(self.got)
                left = deadline - time.time()
                if left <= 0:
                    return None
                self.lock.wait(left)

    def latest(self, kind):
        with self.lock:
            for k, body in reversed(self.got):
                if k == kind:
                    return body
        return None


def agents():
    return json.loads(subprocess.run([CLAUDE, "agents", "--json"], capture_output=True, text=True, timeout=10).stdout)


def start_host():
    exe = os.path.join(ROOT, ".build/release/PortholeHost")
    # No ScreenCaptureKit at all: sessions, transcripts, replies, terminals and tabs don't need it, and it
    # raises macOS's screen-recording prompt on the Mac (attributed to iTerm, which started this).
    env = dict(os.environ, PORTHOLE_TEST_LOOPBACK="1", PORTHOLE_TEST_NO_SCREEN="1")
    log = open(os.path.join(ROOT, ".build/porthole-e2e-host.log"), "w")
    host = subprocess.Popen([exe, "--synthetic"], cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
    for _ in range(100):
        time.sleep(0.2)
        out = subprocess.run(["lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", str(host.pid)], capture_output=True, text=True).stdout
        ports = re.findall(r"127\.0\.0\.1:(\d+)", out)
        if ports:
            if re.search(r"\*:\d+|0\.0\.0\.0:\d+", out):
                host.terminate()
                sys.exit("the test host listens beyond 127.0.0.1; stopped it")
            return host, int(ports[0])
    host.terminate()
    sys.exit("the test host never listened")


# The transcript rules, again in Python, so the host's reading is checked against a second reading.
MACHINE = ("<local-command", "<task-notification>", "<system-reminder>", "<bash-input>", "<bash-stdout>",
           "<bash-stderr>", "<user-prompt-submit-hook>", "<command-message>", "Caveat: The messages below")


def last_word(path):
    """The last prompt or Claude text in a transcript file, as the host's entries show it."""
    last = None
    with open(path, errors="replace") as f:
        for line in f:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get("isSidechain") or r.get("isMeta") or r.get("isCompactSummary"):
                continue
            m = r.get("message") or {}
            c = m.get("content")
            if r.get("type") == "user":
                texts = [c] if isinstance(c, str) else [b.get("text", "") for b in c or [] if isinstance(b, dict) and b.get("type") == "text"]
                for t in texts:
                    t = (t or "").strip()
                    if t and not t.startswith(MACHINE) and "<command-name>" not in t and not t.startswith("[Request interrupted"):
                        last = ("you", t)
            elif r.get("type") == "assistant":
                for b in c or []:
                    if isinstance(b, dict) and b.get("type") == "text" and (b.get("text") or "").strip():
                        last = ("claude", b["text"].strip())
    return last


def osa(script, *args):
    return subprocess.run(["osascript", "-e", script, *args], capture_output=True, text=True, timeout=20).stdout.strip()


def main():
    args = sys.argv[1:]
    host = None
    if "--port" in args:
        port = int(args[args.index("--port") + 1])
    else:
        subprocess.run(["swift", "build", "-c", "release", "--product", "PortholeHost"], cwd=ROOT, check=True, capture_output=True)
        subprocess.run(["swift", "build", "-c", "release", "--product", "PortholeOSAHelper"], cwd=ROOT, check=True, capture_output=True)
        host, port = start_host()
        print(f"test host on 127.0.0.1:{port} (loopback only, synthetic, not advertised)")
    scratch_window = None
    try:
        link = Link(port)

        # sessions
        listed = link.wait(lambda k, b: k == K_SESSIONS, 40)
        if listed is None:
            check("sessions", False, "no session list within 40 s")
            return
        truth = {a["sessionId"] for a in agents()}
        got = {s["id"] for s in (listed or {}).get("sessions", [])}
        if got != truth:   # a session may start or end between the two looks: look once more
            time.sleep(3)
            listed = link.latest(K_SESSIONS) or listed
            got = {s["id"] for s in (listed or {}).get("sessions", [])}
            truth = {a["sessionId"] for a in agents()}
        check("sessions", bool(got) and got == truth, f"{len(got)} listed, {len(truth)} from claude agents"
              + ("" if got == truth else f"; only listed {sorted(got - truth)[:3]}, missing {sorted(truth - got)[:3]}"))
        states = {}
        for s in (listed or {}).get("sessions", []):
            states[s["state"]] = states.get(s["state"], 0) + 1
        print(f"     states: {states}; with a terminal: {sum(1 for s in listed['sessions'] if s.get('terminalID'))}")

        # names: a session that was given a name (a custom-title in its file) is listed by that name, the
        # one `claude agents` shows, not by Claude's own ai-title (every renamed session was, 20 Oct)
        names = {a["sessionId"]: a.get("name") for a in agents()}
        named, wrong = 0, []
        for s in listed["sessions"]:
            path = next(iter(__import__("glob").glob(os.path.expanduser(f"~/.claude/projects/*/{s['id']}.jsonl"))), None)
            if not path or s["id"] not in names:
                continue
            with open(path, "rb") as f:
                if b'"type":"custom-title"' not in f.read():
                    continue
            named += 1
            if s["title"] != names[s["id"]]:
                wrong.append(f"{s['title']!r} for {names[s['id']]!r}")
        check("names", named > 0 and not wrong, f"{named} named sessions" + (f"; wrong: {wrong[:3]}" if wrong else ", each listed by its name"))

        # agent view: Claude Code's `claude agents`, as a text screen in its own colours (agent-view-plan.md)
        def agent_screen(cols, rows, timeout, want):
            """Screens for agent-view until `want(rows_text, screens)` holds; the rows' text, or None."""
            screen, screens, deadline, seen = {}, [], time.time() + timeout, 0
            while time.time() < deadline:
                with link.lock:
                    new = [b for k, b in link.got[seen:] if k == K_SCREEN and b.get("terminalID") == "agent-view"]
                    seen = len(link.got)
                for b in new:
                    if b.get("full"):
                        screen = {}
                    for line in b.get("lines", []):
                        screen[line["row"]] = line.get("runs", [])
                    screens.append(b)
                text = ["".join(r["text"] for r in screen.get(i, [])) for i in range(rows)]
                if screens and want(text, screens):
                    return text, screens, screen
                time.sleep(0.2)
            return None, screens, screen
        link.send(K_WATCH_TERM, {"terminalID": "agent-view", "fitColumns": 100, "fitRows": 30})
        text, screens, cells = agent_screen(100, 30, 20, lambda t, s: any("Claude Code" in row for row in t))
        coloured = sum(1 for runs in cells.values() for r in runs if r.get("fg") is not None)
        check("agent view", text is not None and screens[-1]["columns"] == 100 and coloured > 0,
              f"{len(screens)} screens, 100×30, {coloured} coloured runs" if text else f"no agent view within 20 s ({len(screens)} screens)")
        if text:
            print("     " + "\n     ".join(row.rstrip() for row in text if row.strip())[:600])
            link.send(K_TERM_INPUT, {"terminalID": "agent-view", "text": "porthole check"})
            typed, _, _ = agent_screen(100, 30, 8, lambda t, s: any("porthole check" in row for row in t))
            check("agent view keys", typed is not None, "typed text shows in its prompt" if typed else "typed text never showed")
            link.send(K_TERM_INPUT, {"terminalID": "agent-view", "text": "\x15"})   # ⌃U: clear the prompt again
            link.send(K_WATCH_TERM, {"terminalID": "agent-view", "fitColumns": 80, "fitRows": 24})
            resized, s2, _ = agent_screen(80, 24, 8, lambda t, s: s[-1]["columns"] == 80 and s[-1]["rows"] == 24)
            check("agent view resize", resized is not None, "80×24 after 100×30" if resized else "never resized")
            # colours: dark by default on the device; light on request, the whole screen again in it
            def background_after(colours, want_change_from=None, timeout=10):
                link.send(K_WATCH_TERM, {"terminalID": "agent-view", "fitColumns": 80, "fitRows": 24, "colours": colours})
                deadline, bg = time.time() + timeout, None
                while time.time() < deadline:
                    with link.lock:
                        bg = next((b.get("background") for k, b in reversed(link.got) if k == K_SCREEN and b.get("terminalID") == "agent-view"), None)
                    if bg is not None and bg != want_change_from: break
                    time.sleep(0.2)
                return bg
            first = background_after("light")
            dark_bg = background_after("dark", want_change_from=first if first != 0x002B36 else None)
            light_bg = background_after("light", want_change_from=dark_bg)
            check("agent view colours", dark_bg is not None and light_bg is not None and dark_bg != light_bg,
                  f"dark background #{dark_bg or 0:06X}, light #{light_bg or 0:06X}")
        link.send(K_WATCH_TERM, {"terminalID": "agent-view", "stop": True})

        # mirror: an iTerm session's screen with its own colours (iTerm's Python API), left at its own size
        term = next((s for s in listed["sessions"] if s.get("terminalID")), None)
        if term:
            link.send(K_WATCH_TERM, {"terminalID": term["terminalID"], "windowID": term.get("windowID")})
            got = link.wait(lambda k, b: k == K_SCREEN and b.get("terminalID") == term["terminalID"] and b.get("full"), 15)
            runs = [r for line in (got or {}).get("lines", []) for r in line.get("runs", [])]
            coloured = sum(1 for r in runs if r.get("fg") is not None or r.get("bg") is not None)
            check("mirror colours", got is not None and coloured > 0,
                  f"{term['title']!r}: {got['columns']}×{got['rows']}, {len(runs)} runs, {coloured} coloured" if got
                  else "no screen within 15 s")
            link.send(K_WATCH_TERM, {"terminalID": term["terminalID"], "stop": True})

        # transcript: the session with the newest activity that is not busy, so its file holds still
        sessions = [s for s in listed["sessions"] if s["state"] != "working"]
        pick = max(sessions, key=lambda s: s.get("since") or 0) if sessions else listed["sessions"][0]
        path = next(iter(__import__("glob").glob(os.path.expanduser(f"~/.claude/projects/*/{pick['id']}.jsonl"))), None)
        link.send(K_WATCH, {"sessionID": pick["id"]})
        chunk = link.wait(lambda k, b: k == K_TRANSCRIPT and b.get("sessionID") == pick["id"] and b.get("reset"), 30)
        entries = (chunk or {}).get("entries", [])
        seqs = [e["seq"] for e in entries]
        consecutive = all(a < b for a, b in zip(seqs, seqs[1:])) if seqs else False   # increasing (offset-based numbers)
        words = [e for e in entries if e["role"] in ("you", "claude")]
        expected = last_word(path) if path else None
        same_end = bool(words) and expected is not None and (words[-1]["role"], words[-1]["text"]) == expected
        check("transcript", consecutive and len(entries) <= 200 and same_end,
              f"{pick['title']!r}: {len(entries)} entries, seq {seqs[0] if seqs else '-'}–{seqs[-1] if seqs else '-'}, "
              f"last word {'matches the file' if same_end else 'differs from the file'}")

        # browser: Chrome's tabs, each window matched to a streamable window; a tab brought forward
        # (each window's own active tab, so nothing visible changes)
        chrome = subprocess.run(["pgrep", "-x", "Google Chrome"], capture_output=True).returncode == 0
        tabs = link.wait(lambda k, b: k == K_TABS, 15)
        if not chrome:
            print("     browser checks skipped: Chrome isn't running")
        else:
            wins = (tabs or {}).get("windows", [])
            matched = [w for w in wins if w.get("id")]
            n_tabs = sum(len(w.get("tabs", [])) for w in wins)
            check("browser tabs", tabs is not None and len(wins) > 0 and len(matched) >= len(wins) - 1 and n_tabs >= len(wins),
                  f"{len(wins)} windows ({len(matched)} matched to a window), {n_tabs} tabs")
            for w in matched[:2]:
                active = next((t for t in w["tabs"] if t.get("active")), None)
                if active: link.send(K_ACTIVATE_TAB, {"windowID": w["id"], "tabID": active["id"]})

        # unknown
        link.send(K_REPLY, {"sessionID": "no-such-session", "text": "hello", "token": 9001})
        r = link.wait(lambda k, b: k == K_RESULT and b.get("token") == 9001, 10)
        check("unknown", r is not None and r.get("ok") is False and bool(r.get("reason")), (r or {}).get("reason", "no answer"))

        if "--no-reply" in args:
            print("     reply checks skipped (--no-reply)")
            return

        # A scratch session to reply to: Haiku in ~/dev (a folder Claude Code already trusts here).
        before = {a["sessionId"] for a in agents()}
        wid = osa('tell application "iTerm2" to id of (create window with default profile command '
                  f'"/bin/zsh -lc \'cd ~/dev && exec {CLAUDE} --model haiku\'")')
        scratch_window = wid
        scratch = None
        deadline = time.time() + 45
        while time.time() < deadline and scratch is None:
            time.sleep(2)
            latest = link.latest(K_SESSIONS) or {"sessions": []}
            fresh = [s for s in latest["sessions"] if s["id"] not in before and s.get("terminalID") and str(s.get("windowID")) == wid]
            scratch = fresh[0] if fresh else None
        check("scratch session", scratch is not None, f"iTerm window {wid}" + ("" if scratch else ": never listed with a terminal"))
        if scratch is None:
            return
        # Type only once its prompt shows, as a person would: read its screen until the ❯ line is there.
        ready = False
        for _ in range(30):
            screen = osa(f'tell application "iTerm2" to get contents of current session of (first window whose id is {wid})')
            if "\u276f" in screen and ("mode on" in screen or "shortcuts" in screen):
                ready = True
                break
            time.sleep(1)
        check("scratch ready", ready, "its prompt showed" if ready else "its prompt never showed")
        link.send(K_WATCH, {"sessionID": scratch["id"]})

        def said(role, needle, timeout):
            return link.wait(lambda k, b: k == K_TRANSCRIPT and b.get("sessionID") == scratch["id"]
                             and any(e["role"] == role and needle in e["text"] for e in b.get("entries", [])), timeout)

        # reply
        link.send(K_REPLY, {"sessionID": scratch["id"], "text": "Reply with exactly the word porthole-ok and nothing else.", "token": 1})
        r = link.wait(lambda k, b: k == K_RESULT and b.get("token") == 1, 15)
        typed = said("you", "porthole-ok and nothing else", 30)
        answered = said("claude", "porthole-ok", 90)
        check("reply", bool(r and r.get("ok")) and typed is not None and answered is not None,
              f"typed: {bool(r and r.get('ok'))}, shown as your prompt: {typed is not None}, Claude answered: {answered is not None}")

        def idle(timeout):
            # Until the list says Claude has finished its turn (its hooks included), as a person
            # waits for the answer before writing again.
            deadline = time.time() + timeout
            while time.time() < deadline:
                latest = link.latest(K_SESSIONS) or {"sessions": []}
                mine = next((s for s in latest["sessions"] if s["id"] == scratch["id"]), None)
                if mine and mine["state"] in ("done", "needsYou", "idle"):
                    return True
                time.sleep(1)
            return False

        def screen():
            return osa(f'tell application "iTerm2" to get contents of current session of (first window whose id is {wid})')

        # multiline (and a control character, which must not reach the terminal)
        check("scratch idle", idle(60), "the session finished its turn")
        time.sleep(1)
        text = "Reply with exactly the word two-lines-ok and nothing else.\nThis second line \u001b[31m has an escape."
        link.send(K_REPLY, {"sessionID": scratch["id"], "text": text, "token": 2})
        r = link.wait(lambda k, b: k == K_RESULT and b.get("token") == 2, 15)
        prompt = said("you", "This second line", 30)
        entry = next((e for e in (prompt or {}).get("entries", []) if e["role"] == "you" and "This second line" in e["text"]), None)
        one_prompt = entry is not None and "two-lines-ok" in entry["text"] and "\u001b" not in entry["text"]
        answered = said("claude", "two-lines-ok", 90)
        check("multiline", bool(r and r.get("ok")) and one_prompt and answered is not None,
              f"one prompt with both lines: {one_prompt}, escape removed: {entry is not None and chr(27) not in entry['text']}, Claude answered: {answered is not None}")
        if not one_prompt:
            print("     the scratch session's screen:")
            for line in [l for l in screen().splitlines() if l.strip()][-12:]:
                print("       " + line.rstrip())

        # held: a reply sent while Claude works is held, then typed when it finishes
        check("scratch idle again", idle(60), "the session finished its turn")
        link.send(K_REPLY, {"sessionID": scratch["id"], "text": "Write the numbers from 1 to 250, one per line, then stop.", "token": 3})
        link.wait(lambda k, b: k == K_RESULT and b.get("token") == 3, 15)
        working = False
        deadline = time.time() + 20
        while time.time() < deadline and not working:
            latest = link.latest(K_SESSIONS) or {"sessions": []}
            working = any(s["id"] == scratch["id"] and s["state"] == "working" for s in latest["sessions"])
            time.sleep(0.3)
        link.send(K_REPLY, {"sessionID": scratch["id"], "text": "Reply with exactly the word held-ok and nothing else.", "token": 4})
        first = link.wait(lambda k, b: k == K_RESULT and b.get("token") == 4, 15)
        later = link.wait(lambda k, b: k == K_RESULT and b.get("token") == 4 and b.get("ok"), 120)
        answered = said("claude", "held-ok", 180)   # Haiku first writes out 250 numbers
        check("held", working and bool(first and first.get("queued")) and later is not None and answered is not None,
              f"seen working: {working}, held: {bool(first and first.get('queued'))}, typed after: {later is not None}, Claude answered: {answered is not None}")

        # terminal: the scratch session's screen as text, then keys typed through it
        idle(60)
        latest = link.latest(K_SESSIONS) or {"sessions": []}
        mine = next((s for s in latest["sessions"] if s["id"] == scratch["id"]), scratch)
        link.send(K_WATCH_TERM, {"terminalID": mine["terminalID"], "windowID": mine.get("windowID")})
        first = link.wait(lambda k, b: k == K_SCREEN and b.get("full"), 10)
        lines = ["".join(r["text"] for r in l["runs"]) for l in (first or {}).get("lines", [])]
        check("terminal screen", first is not None and first["rows"] == len(lines) and any("\u276f" in l for l in lines),
              f"{first['columns']}×{first['rows']}, prompt on screen: {any(chr(0x276f) in l for l in lines)}" if first else "no screen")
        link.send(K_TERM_INPUT, {"terminalID": mine["terminalID"], "text": "Reply with exactly the word term-ok and nothing else."})
        echoed = link.wait(lambda k, b: k == K_SCREEN and any("term-ok and nothing" in "".join(r["text"] for r in l["runs"]) for l in b.get("lines", [])), 10)
        link.send(K_TERM_INPUT, {"terminalID": mine["terminalID"], "text": "\r"})
        answered = said("claude", "term-ok", 90)
        check("terminal keys", echoed is not None and answered is not None,
              f"typed text on screen: {echoed is not None}, Claude answered: {answered is not None}")
        # fit: the session takes the device's size while watched, and its own size back after
        size = lambda: osa(f'tell application "iTerm2" to tell current session of (first window whose id is {wid}) to get {{columns, rows}}')
        before = size()
        link.send(K_WATCH_TERM, {"terminalID": mine["terminalID"], "windowID": mine.get("windowID"), "fitColumns": 100, "fitRows": 30})
        fitted = link.wait(lambda k, b: k == K_SCREEN and b.get("full") and b.get("columns") == 100 and b.get("rows") == 30, 10)
        link.send(K_WATCH_TERM, {"terminalID": mine["terminalID"], "stop": True})
        time.sleep(1.5)
        after = size()
        check("terminal fit", fitted is not None and after == before,
              f"fitted to 100×30: {fitted is not None}, back to its own size ({before}): {after == before}")
        # a device that drops while fitted (an app quit, a lost link) still gets the session put back
        other = Link(port)
        other.wait(lambda k, b: k == K_SESSIONS, 40)
        other.send(K_WATCH_TERM, {"terminalID": mine["terminalID"], "windowID": mine.get("windowID"), "fitColumns": 110, "fitRows": 35})
        fitted = other.wait(lambda k, b: k == K_SCREEN and b.get("columns") == 110, 15)
        other.s.close()
        time.sleep(3)
        after = size()
        check("terminal restore on drop", fitted is not None and after == before,
              f"fitted to 110×35: {fitted is not None}, back to {before} after the connection dropped: {after == before} ({after})")

        # ratelimit: six Esc presses at once (harmless while Claude is idle)
        idle(60)
        for i in range(6):
            link.send(K_REPLY, {"sessionID": scratch["id"], "key": "esc", "token": 100 + i})
        results = [link.wait(lambda k, b, t=100 + i: k == K_RESULT and b.get("token") == t, 15) for i in range(6)]
        refused = sum(1 for x in results if x and not x.get("ok"))
        check("ratelimit", refused >= 2 and all(results), f"{refused} of 6 refused")
    finally:
        if scratch_window:
            osa(f'tell application "iTerm2" to close (first window whose id is {scratch_window})')
        if host:
            host.terminate()
            host.wait(timeout=10)


main()
print(f"{'all checks passed' if fails == 0 else f'{fails} check(s) failed'}")
sys.exit(fails)
