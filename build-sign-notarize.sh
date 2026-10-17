#!/bin/bash
# Build MatrixSaver v1.6 (arm64) on asgard, Developer-ID sign OUR code only (never Monroe),
# assert Monroe md5 unchanged, notarize + staple. Output: build/MatrixSaver.app ready to deploy.
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$SRC/build"; APP="$BUILD/MatrixSaver.app"
APPEX="$APP/Contents/PlugIns/MatrixSaver.appex"; SAVER="$APPEX/Contents/Resources/Matrix.saver"
APPID="Developer ID Application: Rodion Nazarov (LGAQBC2VM2)"
MONROE_MD5="b578c8f67450045cc653966c2992f86c"

echo "=== clean build ==="
rm -rf "$BUILD"; mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources" "$APP/Contents/MacOS"
clang -fobjc-arc -O2 -arch arm64 -mmacosx-version-min=14.0 \
  -framework ScreenSaver -framework AppKit -framework Foundation -e _NSExtensionMain \
  "$SRC/MatrixView.m" "$SRC/MatrixSaver.m" -o "$APPEX/Contents/MacOS/MatrixSaver"
cp "$SRC/Info-appex.plist" "$APPEX/Contents/Info.plist"
[ -d "$SRC/Matrix.saver" ] && cp -R "$SRC/Matrix.saver" "$APPEX/Contents/Resources/" || { echo "FATAL: Matrix.saver missing"; exit 1; }
clang -fobjc-arc -O2 -arch arm64 -mmacosx-version-min=14.0 -framework Cocoa "$SRC/AppMain.m" -o "$APP/Contents/MacOS/MatrixSaverHost"
cp "$SRC/Info-app.plist" "$APP/Contents/Info.plist"

B=$(md5 -q "$SAVER/Contents/MacOS/"* | head -1)
echo "Monroe md5 before signing = $B"
[ "$B" = "$MONROE_MD5" ] || { echo "FATAL: source Monroe md5 mismatch ($B != $MONROE_MD5)"; exit 8; }

echo "=== Developer-ID sign OUR code only (Monroe is NOT touched) ==="
codesign -f -s "$APPID" --timestamp --options runtime --entitlements "$SRC/appex.entitlements" "$APPEX/Contents/MacOS/MatrixSaver"
codesign -f -s "$APPID" --timestamp --options runtime --entitlements "$SRC/appex.entitlements" "$APPEX"
codesign -f -s "$APPID" --timestamp --options runtime "$APP/Contents/MacOS/MatrixSaverHost"
codesign -f -s "$APPID" --timestamp --options runtime "$APP"

A=$(md5 -q "$SAVER/Contents/MacOS/"* | head -1)
echo "Monroe md5 after signing  = $A"
[ "$B" = "$A" ] || { echo "FATAL_SAVER_CHANGED ($B != $A)"; exit 9; }

echo "=== verify ==="
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -3

echo "=== notarize + staple ==="
~/.claude/skills/macos-codesign/notarize.sh --target "$APP" 2>&1 | tail -15

echo "=== gatekeeper verdicts ==="
xcrun stapler validate "$APP" 2>&1 | tail -1
spctl -a -vvv --type exec "$APP" 2>&1 | tail -3
echo "BUILD_DONE $(codesign -dvv "$APPEX" 2>&1 | grep -i 'CodeDirectory\|flags' | head -1)"
