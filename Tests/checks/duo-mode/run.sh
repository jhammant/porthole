#!/bin/bash
# The iPhone Duo's laptop or whole screen (iOSClient/PortholeDuoMode.swift): held upright, half-folded is
# the laptop and open flat the whole screen unless the Settings panel says otherwise; sideways only the
# book pose's fold divides the sidebar; every other pose keeps its own layout.
#   Tests/checks/duo-mode/run.sh    compile and run the check
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
if [ "${1:-}" = "--mutants" ]; then echo "$name: no mutants"; exit 0; fi
rm -f "$out/check"
swiftc -O "$root/iOSClient/DuoPosture.swift" "$root/iOSClient/PortholeDuoMode.swift" "$here/main.swift" -o "$out/check" 2>&1 | grep -E "error" || true
[ -x "$out/check" ] || { echo "$name: did not compile" >&2; exit 1; }
"$out/check"
