#!/bin/bash
# Porthole's iPhone and iPad app to TestFlight (docs/porthole-plan.md, phase 5).
#
#   Scripts/porthole-testflight.sh KEY_ID ISSUER_ID [--build N] [--store]
#
# KEY_ID and ISSUER_ID: an App Store Connect API key (App Manager) whose AuthKey_<KEY_ID>.p8 is in
# ~/.appstoreconnect/private_keys/. The key never leaves that file: xcodebuild reads it there. Archives
# with Xcode 27.1 (the iPhone Duo's hinge needs its SDK; set PORTHOLE_XCODE to use another), signs for
# team 9HPLKKTW4L automatically, and uploads for internal testers (no review). --build sets the build
# number (App Store Connect refuses one it has seen); without it, the project's number is used.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
key_id="${1:?usage: $0 KEY_ID ISSUER_ID [--build N] [--store]}"
issuer="${2:?usage: $0 KEY_ID ISSUER_ID [--build N] [--store]}"
shift 2
build="" store=0
while [ $# -gt 0 ]; do
    case "$1" in
        --build) build="${2:?--build needs a number}"; shift 2 ;;
        --store) store=1; shift ;;   # an App Store build: not marked for internal testers only
        *) echo "usage: $0 KEY_ID ISSUER_ID [--build N] [--store]" >&2; exit 2 ;;
    esac
done
key="$HOME/.appstoreconnect/private_keys/AuthKey_${key_id}.p8"
[ -f "$key" ] || { echo "error: $key is missing (download it from App Store Connect › Integrations)" >&2; exit 1; }
export DEVELOPER_DIR="${PORTHOLE_XCODE:-/Applications/Xcode-27.1-beta.app/Contents/Developer}"
# Apple's tools first: Xcode packages the app with /usr/bin/rsync and an Apple-only flag, and the rsync it
# starts at the other end is found on PATH, where Homebrew's (3.4.1) refuses it ("--extended-attributes:
# unknown option", 17 Oct).
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
out="$root/.build/testflight"
rm -rf "$out"; mkdir -p "$out"
auth=(-allowProvisioningUpdates -authenticationKeyPath "$key" -authenticationKeyID "$key_id" -authenticationKeyIssuerID "$issuer")
# PORTHOLE_APPSTORE: the App Store's build asks StoreKit for Pro (PortholePro); built from source, Pro is on.
extra=(SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) PORTHOLE_APPSTORE')
if [ -n "$build" ]; then extra+=(CURRENT_PROJECT_VERSION="$build"); fi
echo "Archiving with $(xcodebuild -version | head -1)…"
xcodebuild -project iOSClient/Porthole.xcodeproj -scheme Porthole -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$out/Porthole.xcarchive" "${auth[@]}" ${extra[@]+"${extra[@]}"} archive | tail -3
echo "Uploading to App Store Connect…"
options=Packaging/PortholeExportOptions.plist
if [ "$store" = 1 ]; then
    # Internal-only builds can never be submitted to the App Store (buildAudienceType INTERNAL_ONLY).
    cp "$options" "$out/ExportOptions.plist"; options="$out/ExportOptions.plist"
    /usr/libexec/PlistBuddy -c "Set :testFlightInternalTestingOnly false" "$options"
fi
xcodebuild -exportArchive -archivePath "$out/Porthole.xcarchive" -exportPath "$out/export" \
    -exportOptionsPlist "$options" "${auth[@]}" | tail -5
echo "Uploaded. App Store Connect processes it (usually 15–30 minutes); then it shows in TestFlight."
