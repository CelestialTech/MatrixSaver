#!/bin/bash
# Build + install the modern Matrix screen-saver .appex (macOS 14+/27).
set -e
SRC="$HOME/src/MatrixSaver"
BUILD="$SRC/build"
APP="$BUILD/MatrixSaver.app"
APPEX="$APP/Contents/PlugIns/MatrixSaver.appex"
DEST="$HOME/Applications/MatrixSaver.app"

rm -rf "$BUILD"
mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"
mkdir -p "$APP/Contents/MacOS"

echo "=== compile appex executable (arm64) ==="
clang -fobjc-arc -O2 -arch arm64 -mmacosx-version-min=14.0 \
    -framework ScreenSaver -framework AppKit -framework Foundation \
    -e _NSExtensionMain \
    "$SRC/MatrixView.m" "$SRC/MatrixSaver.m" \
    -o "$APPEX/Contents/MacOS/MatrixSaver"
cp "$SRC/Info-appex.plist" "$APPEX/Contents/Info.plist"
echo "appex exec:"; file "$APPEX/Contents/MacOS/MatrixSaver"

echo "=== compile host app executable ==="
clang -fobjc-arc -O2 -arch arm64 -mmacosx-version-min=14.0 \
    -framework Cocoa "$SRC/AppMain.m" \
    -o "$APP/Contents/MacOS/MatrixSaverHost"
cp "$SRC/Info-app.plist" "$APP/Contents/Info.plist"

echo "=== ad-hoc codesign (inside-out) ==="
codesign -f -s - --timestamp=none "$APPEX"
codesign -f -s - --timestamp=none "$APP"
echo "--- verify ---"
codesign -dv "$APPEX" 2>&1 | head -3 || true

echo "=== install to ~/Applications ==="
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"

echo "=== register with LaunchServices + PluginKit ==="
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
"$LSREG" -f "$DEST" || true
pluginkit -a "$DEST/Contents/PlugIns/MatrixSaver.appex" 2>&1 || true
sleep 1

echo "=== is it registered on com.apple.screensaver? ==="
pluginkit -m -p com.apple.screensaver -vvv 2>/dev/null | grep -i "matrix\|celestialtech" || echo "(not yet listed)"
echo "DONE"
