#!/bin/bash
# Modified by Jon Hammant, 2026, as part of Porthole (see NOTICE).
# usage: build.sh WT OUT [FILE=OVERRIDE ...]
# Compiles the check with StreamProtocol's sources as one module, -package-name porthole for the host
# files' `package` access. The host files named in HOST_FILES are added with their
# `import StreamProtocol` stripped; FILE=OVERRIDE (a basename, then a path) compiles OVERRIDE in
# FILE's place (the mutants').
WT=$1; OUT=$2; shift 2; T=$(mktemp -d)
HOST_FILES=(MenuFormat.swift MenuPolicy.swift)
cp "$WT"/Sources/StreamProtocol/*.swift "$T"/
for f in ${HOST_FILES[@]+"${HOST_FILES[@]}"}; do
    src="$WT/Sources/PortholeHost/$f"
    for o in "$@"; do [ "${o%%=*}" = "$f" ] && src="${o#*=}"; done
    sed '/^import StreamProtocol$/d' "$src" > "$T/$f"
done
for o in "$@"; do
    f="${o%%=*}"
    [ -f "$WT/Sources/StreamProtocol/$f" ] && cp "${o#*=}" "$T/$f"
done
cp "$(dirname "$0")/main.swift" "$T/main.swift"
swiftc -O -package-name porthole "$T"/*.swift -o "$OUT" 2>&1 | grep -E "error" ; rm -rf "$T"
