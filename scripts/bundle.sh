#!/bin/zsh
# Builds TouchBridge.app into ./build and signs it.
# Signing with a stable identity keeps macOS privacy grants (Accessibility, Input Monitoring) across rebuilds;
# ad-hoc signing works but macOS forgets the grants after every build.
set -euo pipefail

cd "${0:A:h}/.."
IDENTITY="${TOUCHBRIDGE_SIGN_IDENTITY:-TouchBridge Dev}"
APP="build/TouchBridge.app"

swift build -c release --product TouchBridgeApp

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TouchBridgeApp "$APP/Contents/MacOS/TouchBridge"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if security find-identity -p codesigning | grep -qF "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Signed with \"$IDENTITY\"."
else
    codesign --force --sign - "$APP"
    echo "WARNING: signing identity \"$IDENTITY\" not found; signed ad-hoc. Privacy grants will reset on every build."
fi

codesign --verify --verbose=1 "$APP"
echo "Built $PWD/$APP"
