#!/bin/bash
# Back and forward through what was on screen (iOSClient/PortholeBackForward.swift): a browser's rules.
#   Tests/checks/backforward/run.sh    compile and run the check
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
if [ "${1:-}" = "--mutants" ]; then echo "$name: no mutants"; exit 0; fi
rm -f "$out/check"
swiftc -O "$root/iOSClient/PortholeBackForward.swift" "$here/main.swift" -o "$out/check" 2>&1 | grep -E "error" || true
[ -x "$out/check" ] || { echo "$name: did not compile" >&2; exit 1; }
"$out/check"
