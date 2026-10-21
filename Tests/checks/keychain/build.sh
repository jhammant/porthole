#!/bin/bash
# Modified by Jon Hammant, 2026, as part of Porthole (see NOTICE).
# usage: build.sh WT OUT [IdentityStorePlan.swift override]
# Compiles the pure store-selection rule (Sources/PortholeMenuBar/IdentityStorePlan.swift, Foundation
# only) with this check's main.swift. No StreamProtocol, no bundle, no keychain.
WT=$1; OUT=$2; T=$(mktemp -d)
cp "${3:-$WT/Sources/PortholeMenuBar/IdentityStorePlan.swift}" "$T/IdentityStorePlan.swift"
cp "$(dirname "$0")/main.swift" "$T/main.swift"
swiftc -O "$T"/*.swift -o "$OUT" 2>&1 | grep -E "error" ; rm -rf "$T"
