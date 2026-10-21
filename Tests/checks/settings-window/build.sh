#!/bin/bash
# Modified by Jon Hammant, 2026, as part of Porthole (see NOTICE).
# usage: build.sh WT OUT [SettingsWindowFit.swift override]
# Compiles the Settings window's arithmetic (Sources/PortholeMenuBar/SettingsWindowFit.swift, CoreGraphics
# only) with this check's main.swift. No AppKit, no window, no screen.
WT=$1; OUT=$2; T=$(mktemp -d)
cp "${3:-$WT/Sources/PortholeMenuBar/SettingsWindowFit.swift}" "$T/SettingsWindowFit.swift"
cp "$(dirname "$0")/main.swift" "$T/main.swift"
swiftc -O "$T"/*.swift -o "$OUT" 2>&1 | grep -E "error" ; rm -rf "$T"
