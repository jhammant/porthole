#!/bin/bash
# Modified by Jon Hammant, 2026, as part of Porthole (see NOTICE).
# usage: build.sh WT OUT [PointerWatch.swift override]
# Compiles PointerWatch.swift with PointerControl.swift, Stats.swift and StreamProtocol's sources as
# one module (each `import StreamProtocol` stripped), with -package-name porthole for Stats' `package`
# access.
WT=$1; OUT=$2; T=$(mktemp -d)
cp "$WT"/Sources/StreamProtocol/*.swift "$T"/
sed '/^import StreamProtocol$/d' "${3:-$WT/Sources/PortholeHost/PointerWatch.swift}" > "$T/PointerWatch.swift"
sed '/^import StreamProtocol$/d' "$WT/Sources/PortholeHost/PointerControl.swift" > "$T/PointerControl.swift"
cp "$WT/Sources/PortholeHost/Stats.swift" "$T/Stats.swift"
cp "$(dirname "$0")/main.swift" "$T/main.swift"
swiftc -O -package-name porthole "$T"/*.swift -o "$OUT" 2>&1 | grep -E "error" ; rm -rf "$T"
