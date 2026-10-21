#!/bin/bash
# Modified by Jon Hammant, 2026, as part of Porthole (see NOTICE).
# OriginPolicy with InterfaceSnapshot (Sources/PortholeHost): which door (home or remote) a connection
# may use, judged by its source address and the interface it arrived on. The last checks read this
# Mac's own interfaces (getifaddrs, read-only).
#   Tests/checks/origin/run.sh             compile and run the check
#   Tests/checks/origin/run.sh --mutants   one-line mutants of OriginPolicy.swift; each must fail it
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
if [ "${1:-}" = "--mutants" ]; then run_mutants python3 "$here/mutants.py" "$root"; exit; fi
swiftc -O Sources/PortholeHost/OriginPolicy.swift Sources/PortholeHost/InterfaceSnapshot.swift "$here/main.swift" -o "$out/check"
"$out/check"
