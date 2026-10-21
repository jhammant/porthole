#!/bin/bash
# Modified by Jon Hammant, 2026, as part of Porthole (see NOTICE).
# usage: build.sh WT OUT [DeviceGate.swift override]
# Compiles DeviceGate.swift with StreamProtocol's sources as one module (its `import StreamProtocol`
# stripped), with -package-name porthole for its `package` access.
WT=$1; OUT=$2; T=$(mktemp -d)
cp "$WT"/Sources/StreamProtocol/*.swift "$T"/
sed '/^import StreamProtocol$/d' "${3:-$WT/Sources/PortholeHost/DeviceGate.swift}" > "$T/DeviceGate.swift"
cp "$(dirname "$0")/main.swift" "$T/main.swift"
swiftc -O -package-name porthole "$T"/*.swift -o "$OUT" 2>&1 | grep -E "error" ; rm -rf "$T"
