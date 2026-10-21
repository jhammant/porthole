#!/bin/bash
# Modified by Jon Hammant, 2026, as part of Porthole (see NOTICE).
# usage: build.sh ROOT OUT [SOURCE=OVERRIDE ...]
# Compiles HostConfig.swift, DeviceSettings.swift, AwayPolicy.swift and OriginPolicy.swift (Sources/PortholeHost)
# with StreamProtocol's HostSettings.swift as one module, `import StreamProtocol` stripped, and
# -package-name porthole for their `package` access. An OVERRIDE replaces one file by its name (a mutant).
ROOT=$1; OUT=$2; shift 2
T=$(mktemp -d)
cp "$ROOT/Sources/StreamProtocol/HostSettings.swift" "$T/"
for f in HostConfig DeviceSettings AwayPolicy OriginPolicy; do
    sed '/^import StreamProtocol$/d' "$ROOT/Sources/PortholeHost/$f.swift" > "$T/$f.swift"
done
for o in "$@"; do
    name="${o%%=*}"; src="${o#*=}"
    sed '/^import StreamProtocol$/d' "$src" > "$T/$name"
done
cp "$(dirname "$0")/main.swift" "$T/main.swift"
swiftc -O -package-name porthole "$T"/*.swift -o "$OUT" 2>&1 | grep -E "error" ; rm -rf "$T"
