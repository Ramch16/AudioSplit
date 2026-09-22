#!/bin/bash
# Build a release AudioSplit.app and wrap it in a DMG.
#
#   Scripts/make-dmg.sh
#
# Signs with a Developer ID Application certificate when one is present. That
# is what Gatekeeper requires on someone else's Mac: an Apple Development
# certificate is fine for your own machine but produces "Apple could not verify
# this app is free of malware" anywhere else. Developer ID needs a paid Apple
# Developer Program membership.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  Sources/AudioSplitApp/Info.plist)"
APP="dist/AudioSplit.app"
DMG="dist/AudioSplit-$VERSION.dmg"
STAGING="dist/dmg-staging"

# `|| true` matters: under `set -e` an assignment takes the exit status of its
# command substitution, so a failing grep would kill the script at exactly the
# "no Developer ID certificate" case this is trying to explain.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning \
    | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)".*/\1/' || true)"
fi

if [ -z "$IDENTITY" ]; then
  cat <<'WARN'
warning: no Developer ID Application certificate found.

  The DMG will still be built, but the app inside is signed for local use
  only. On any other Mac, Gatekeeper will refuse to open it.

  To distribute:
    1. Join the Apple Developer Program (paid).
    2. Create a Developer ID Application certificate.
    3. Re-run this script, then Scripts/notarize.sh.
WARN
fi

CONFIG=release CODESIGN_IDENTITY="$IDENTITY" Scripts/make-app.sh AudioSplitApp

echo "==> verifying the signature Gatekeeper will see"
codesign --verify --deep --strict --verbose=2 "$APP"
# Hardened Runtime is mandatory for notarization; fail loudly rather than
# discovering it after upload.
#
# Captured into a variable first, deliberately. Piping straight into `grep -q`
# makes grep exit on the first match, codesign take SIGPIPE, and `pipefail`
# report the whole pipeline as failed — so a *successful* match looked like a
# missing Hardened Runtime.
SIGNATURE="$(codesign -dv --verbose=2 "$APP" 2>&1)"
case "$SIGNATURE" in
  *"flags=0x10000(runtime)"*) : ;;
  *)
    echo "error: Hardened Runtime is not enabled on $APP" >&2
    echo "$SIGNATURE" | grep -i flags >&2 || true
    exit 1
    ;;
esac

echo "==> staging"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
# The familiar drag-to-install layout.
ln -s /Applications "$STAGING/Applications"

echo "==> building $DMG"
hdiutil create -volname "AudioSplit" -srcfolder "$STAGING" -ov -format ULFO "$DMG" >/dev/null
rm -rf "$STAGING"

echo "built: $DMG"
echo "size:  $(du -h "$DMG" | cut -f1)"
