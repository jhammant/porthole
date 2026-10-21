#!/bin/bash
# Porthole's pure parts (docs/porthole-plan.md, Judges): the transcript reader and the session states,
# the sidebar's order and portals, iTerm titles, reply sanitising, tile frames and the terminal's screen
# rows. Sources/StreamProtocol and the host's Porthole files compiled as one module with the check (their
# `import StreamProtocol` lines taken out, as the away-quality check does).
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
T=$(mktemp -d)
cp Sources/StreamProtocol/*.swift "$T/"
for f in PortholeTranscript PortholeSessions; do sed '/^import StreamProtocol$/d' "Sources/PortholeHost/$f.swift" > "$T/$f.swift"; done
cp "$here/main.swift" "$T/main.swift"
swiftc -O -package-name porthole "$T"/*.swift -o "$out/check"
rm -rf "$T"
"$out/check"
