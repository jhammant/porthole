#!/bin/bash
# The Desktop's pinch zoom on the device (iOSClient/PortholeZoom.swift): the point under the fingers
# stays under them, the picture never shrinks below the panel or leaves its edges, and the rect the
# picture is drawn in is the rect touches are mapped through.
#   Tests/checks/zoom/run.sh    compile and run the check
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
if [ "${1:-}" = "--mutants" ]; then echo "$name: no mutants"; exit 0; fi
rm -f "$out/check"
swiftc -O "$root/iOSClient/PortholeZoom.swift" "$here/main.swift" -o "$out/check" 2>&1 | grep -E "error" || true
[ -x "$out/check" ] || { echo "$name: did not compile" >&2; exit 1; }
"$out/check"
