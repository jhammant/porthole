# Porthole

Your Mac, and every Claude Code session running on it, on your iPad or iPhone. Porthole streams any Mac
window, or a whole screen, and takes your touch, trackpad, Pencil and keyboard back, so the Mac is in
your hands when you're away from the desk. It was built for keeping an eye on (and talking to) coding
agents from the sofa, a train or a café, and works for any Mac app.

Two apps:

- **Porthole for Mac**: a menu bar app that streams a window, a screen, or two or four windows tiled, and
  lists every Claude Code session on the Mac, the ones waiting for you first.
- **Porthole for iPad and iPhone**: a sidebar of sessions and Mac apps beside the Mac's own picture.

## What it does

- **Claude Code sessions in a sidebar**, grouped and sorted with the ones that need you first. A session
  opens its terminal window, fitted to your screen, or as **text** in its own colours (sharp at any link
  speed), or as text with **Claude Code's agent view** beside it. The agent view is also one tap away.
  **OpenAI Codex** sessions in a terminal show up too, tagged Codex.
- **Any Mac app**: its windows, Chrome's tabs, your favourite apps with their own hot keys (long-press to
  add, reorder or re-key them), every installed app, and the whole screen, on any of your Mac's displays.
- **Tiles**: two windows side by side, or four in a grid.
- **Input that feels native**: touch, a trackpad, the Apple Pencil, a hardware keyboard and Mac shortcuts,
  trackpad gestures, pinch to zoom the desktop, and copy and paste both ways.
- **Hot keys** for everything: next and previous window, back and forward, sessions, apps, the sidebar
  and the top bar (hold ⌘ to see them all).
- **iPhone Duo**: every pose. Half-folded it is a tiny laptop, with a full Mac keyboard and trackpad on the
  lower half; open flat the Mac fills the whole screen (each pose's choice is in Settings). Or use a folding
  keyboard and mouse.
- **At home or away**: found on your network with Bonjour; away from home through Tailscale or any VPN,
  with the quality following the link.
- **Private by design**: your devices talk to your Mac directly over an encrypted, paired connection.
  No accounts, no servers, no analytics. See [PRIVACY.md](PRIVACY.md).

There may also be a hidden mode. Follow the white rabbit.

## Install

- **Mac**: download Porthole.app from [Releases](../../releases), move it to Applications and open it. It
  asks for Screen Recording and Accessibility (to stream windows and send your input). Requires macOS 14
  or later.
- **iPad and iPhone**: from the App Store, or join the TestFlight beta (link in Releases). Requires iOS 17
  or later. Open it on the same network as your Mac and pair with the code the Mac shows: scan it, or
  click Copy Link on the Mac and tap Paste on the device (Universal Clipboard carries it over).
- **Away from home**: put both on [Tailscale](https://tailscale.com) (or your own VPN) and turn on
  Remote access in the Mac app's Settings.
- **Sessions as text in colour** (optional): Porthole reads iTerm2 through its Python API.
  Turn on iTerm2 › Settings › General › Magic › Enable Python API, then run once:

  ```bash
  python3 -m venv ~/Library/Application\ Support/Porthole/venv
  ~/Library/Application\ Support/Porthole/venv/bin/pip install iterm2
  ```

- **Session groups** (optional): name your groups in `~/Library/Application Support/Porthole/groups.json`,
  for example `[{"folder": "dev/acme", "label": "Acme"}]`. Without it, a session's group is its folder
  under `~/dev`.

## Build

The Mac app, installed in /Applications and launched:

```bash
Scripts/make-app.sh --install --open
```

The iOS app: open `iOSClient/Porthole.xcodeproj`, scheme Porthole, set your own team and bundle
identifier, and run. Tools: Xcode 27.1 (the iPhone Duo's hinge needs its SDK), macOS 14 or later.
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) has the details.

## Checks

```bash
Tests/checks/run-all.sh          # the pure checks, protocol to policy
Scripts/porthole-e2e.py          # against a real host on this Mac (PORTHOLE_TEST_NO_SCREEN=1: no capture)
```

## Licence

Apache License 2.0 ([LICENSE](LICENSE)); see [NOTICE](NOTICE) for what Porthole is derived from and
the fonts and libraries it includes.
