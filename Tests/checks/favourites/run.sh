#!/bin/bash
# Jon's favourite apps (iOSClient/PortholeFavouritesList.swift): adding, removing, moving and re-lettering.
#   Tests/checks/favourites/run.sh    compile and run the check
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
if [ "${1:-}" = "--mutants" ]; then echo "$name: no mutants"; exit 0; fi
rm -f "$out/check"
swiftc -O "$root/iOSClient/PortholeFavouritesList.swift" "$here/main.swift" -o "$out/check" 2>&1 | grep -E "error" || true
[ -x "$out/check" ] || { echo "$name: did not compile" >&2; exit 1; }
"$out/check"
