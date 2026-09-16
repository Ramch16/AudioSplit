#!/bin/bash
# Assemble a command-line target into a signed .app bundle.
#
# A process tap returns silence — not an error — until TCC has granted audio
# capture. TCC will only prompt for something with its own bundle identity and
# its own responsibility; a binary run from a terminal inherits the terminal's,
# so it can never be granted on its own. Hence the bundle.
#
#   Scripts/make-app.sh audiosplit-m3
set -euo pipefail

cd "$(dirname "$0")/.."
PRODUCT="${1:?usage: make-app.sh <product name>}"
CONFIG="${CONFIG:-debug}"
PLIST="Sources/$PRODUCT/Info.plist"
NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$PLIST")"
# Milestone harnesses go in a subfolder. They are headless agents that start
# tapping the moment they launch, so they must not sit next to the real app
# where they can be double-clicked by mistake.
case "$PRODUCT" in
  AudioSplitApp) APP="dist/$NAME.app" ;;
  *)             APP="dist/harnesses/$NAME.app" ;;
esac
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | grep -m1 "Apple Development" | sed -E 's/.*"(.*)".*/\1/')}"

swift build -c "$CONFIG" --product "$PRODUCT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/$CONFIG/$PRODUCT" "$APP/Contents/MacOS/$PRODUCT"
cp "$PLIST" "$APP/Contents/Info.plist"

# Add, or Set if the source plist already declares it.
plist_put() {
  /usr/libexec/PlistBuddy -c "Add :$1 $2 $3" "$APP/Contents/Info.plist" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c "Set :$1 $3" "$APP/Contents/Info.plist" >/dev/null
}
plist_put CFBundleExecutable string "$PRODUCT"
plist_put CFBundlePackageType string APPL

# The icon is generated from Scripts/make-icon.swift, so a fresh checkout that
# has not run it still produces a properly badged app.
if [ "$PRODUCT" = "AudioSplitApp" ]; then
  if [ ! -f Resources/AppIcon.icns ]; then
    echo "generating app icon..."
    swift Scripts/make-icon.swift
    iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
  fi
  mkdir -p "$APP/Contents/Resources"
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
  echo "signed with: $IDENTITY"
else
  codesign --force --sign - "$APP"
  echo "signed ad-hoc (no Apple Development identity found)"
fi

echo "built: $APP"
