#!/bin/bash
# Porthole for Mac for download (GitHub Releases): built, signed with a Developer ID Application identity
# and the hardened runtime, notarised by Apple, stapled, zipped.
#
#   Scripts/porthole-release-mac.sh KEY_ID ISSUER_ID      → .build/release-mac/Porthole-<version>.zip
#
# KEY_ID and ISSUER_ID: an App Store Connect API key whose AuthKey_<KEY_ID>.p8 is in
# ~/.appstoreconnect/private_keys/ (the one Scripts/porthole-testflight.sh takes); notarytool reads it
# there. The Developer ID Application certificate must be in the login keychain: Xcode › Settings ›
# Accounts › the team › Manage Certificates › + › Developer ID Application (the account holder only).
set -euo pipefail
cd "$(dirname "$0")/.."
key_id="${1:?usage: Scripts/porthole-release-mac.sh KEY_ID ISSUER_ID}"
issuer="${2:?usage: Scripts/porthole-release-mac.sh KEY_ID ISSUER_ID}"
key="$HOME/.appstoreconnect/private_keys/AuthKey_${key_id}.p8"
[ -f "$key" ] || { echo "No $key" >&2; exit 2; }
identity="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application: / { print $2; exit }')"
[ -n "$identity" ] || { echo "No Developer ID Application certificate in the keychain (see the top of this script)" >&2; exit 2; }

PORTHOLE_SIGN_IDENTITY="$identity" Scripts/make-app.sh
app=".build/Porthole.app"
# Signed again for release: a secure timestamp and the release entitlements, the nested helper first.
codesign --force --options runtime --timestamp --entitlements Packaging/PortholeHelper.entitlements --sign "$identity" "$app/Contents/MacOS/PortholeOSAHelper"
codesign --force --options runtime --timestamp --entitlements Packaging/PortholeRelease.entitlements --sign "$identity" "$app"
codesign --verify --strict --deep "$app"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
out=".build/release-mac"
mkdir -p "$out"
zip="$out/Porthole-$version.zip"
ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --key "$key" --key-id "$key_id" --issuer "$issuer" --wait
xcrun stapler staple "$app"
ditto -c -k --keepParent "$app" "$zip"      # again, with the ticket stapled in
spctl --assess --type execute --verbose=2 "$app"
echo "Ready: $zip ($(du -h "$zip" | cut -f1)), Porthole $version, signed by $identity, notarised and stapled."
