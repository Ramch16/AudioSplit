#!/bin/bash
# Submit the DMG to Apple for notarization and staple the result.
#
#   xcrun notarytool store-credentials AudioSplit \
#     --apple-id you@example.com --team-id TEAMID --password app-specific-pw
#   Scripts/notarize.sh dist/AudioSplit-1.0.dmg
#
# Credentials live in the keychain under a profile name, never in this repo.
# The password is an app-specific password from appleid.apple.com, not your
# Apple ID password.
set -euo pipefail

cd "$(dirname "$0")/.."
DMG="${1:?usage: notarize.sh <path to .dmg>}"
PROFILE="${NOTARY_PROFILE:-AudioSplit}"

echo "==> submitting $DMG (this waits for Apple, usually a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "==> stapling the ticket so it works offline"
xcrun stapler staple "$DMG"

echo "==> verifying as Gatekeeper would"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo "notarized: $DMG"
