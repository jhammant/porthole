#!/bin/bash
# The search across sessions on the Mac (Sources/PortholeHost/PortholeSearch.swift): grep's offsets read back
# as the transcript reads its lines, your prompts, Claude's words and tool lines matching, ignoring case;
# tool results, thinking and side chains never; newest first in a session and across sessions.
#   Tests/checks/search/run.sh    compile and run the check
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
if [ "${1:-}" = "--mutants" ]; then echo "$name: no mutants"; exit 0; fi
src="$out/src"
mkdir -p "$src"
cp Sources/StreamProtocol/*.swift "$src/"
for f in PortholeTranscript PortholeSearch; do sed '/^import StreamProtocol$/d' "Sources/PortholeHost/$f.swift" > "$src/$f.swift"; done
cp "$here/main.swift" "$src/main.swift"
rm -f "$out/check"
swiftc -O -package-name porthole "$src"/*.swift -o "$out/check" 2>&1 | grep -E "error" || true
[ -x "$out/check" ] || { echo "$name: did not compile" >&2; exit 1; }
"$out/check" "$out"
