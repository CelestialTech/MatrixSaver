#!/bin/bash
# Distributable MatrixSaver release: Developer ID signed + notarizable, appex SANDBOXED,
# installs to the USER's ~/Applications (user-owned) and selects Matrix as the screen saver.
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC/Info-app.plist")"
BUILD="$SRC/build"; APP="$BUILD/MatrixSaver.app"
APPEX="$APP/Contents/PlugIns/MatrixSaver.appex"; SAVER="$APPEX/Contents/Resources/Matrix.saver"
DIST="$SRC/dist"
APPID="Developer ID Application: Rodion Nazarov (LGAQBC2VM2)"
INSTID="Developer ID Installer: Rodion Nazarov (LGAQBC2VM2)"

echo "=== clean build (v$VERSION) ==="
rm -rf "$BUILD" "$DIST"; mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources" "$APP/Contents/MacOS" "$DIST"
clang -fobjc-arc -O2 -arch arm64 -mmacosx-version-min=14.0 \
  -framework ScreenSaver -framework AppKit -framework Foundation -e _NSExtensionMain \
  "$SRC/MatrixView.m" "$SRC/MatrixSaver.m" -o "$APPEX/Contents/MacOS/MatrixSaver"
cp "$SRC/Info-appex.plist" "$APPEX/Contents/Info.plist"
[ -d "$SRC/Matrix.saver" ] && cp -R "$SRC/Matrix.saver" "$APPEX/Contents/Resources/" || { echo "FATAL: Matrix.saver missing"; exit 1; }
clang -fobjc-arc -O2 -arch arm64 -mmacosx-version-min=14.0 -framework Cocoa "$SRC/AppMain.m" -o "$APP/Contents/MacOS/MatrixSaverHost"
cp "$SRC/Info-app.plist" "$APP/Contents/Info.plist"

echo "=== Developer ID sign (bottom-up, hardened; appex sandboxed) ==="
if [ -d "$SAVER/Contents/MacOS" ]; then
  find "$SAVER/Contents/MacOS" -type f | while read -r f; do codesign -f -s "$APPID" --timestamp --options runtime "$f"; done
  codesign -f -s "$APPID" --timestamp --options runtime "$SAVER"
fi
codesign -f -s "$APPID" --timestamp --options runtime "$APPEX/Contents/MacOS/MatrixSaver"
codesign -f -s "$APPID" --timestamp --options runtime --entitlements "$SRC/entitlements-appex.plist" "$APPEX"
codesign -f -s "$APPID" --timestamp --options runtime "$APP/Contents/MacOS/MatrixSaverHost"
codesign -f -s "$APPID" --timestamp --options runtime "$APP"
echo "--- verify ---"; codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2

echo "=== per-user .pkg (installs to ~/Applications + selects Matrix) ==="
STAGE="$BUILD/pkgroot"; SCRIPTS="$BUILD/scripts"
mkdir -p "$STAGE/Library/Application Support/MatrixSaver" "$SCRIPTS"
cp -R "$APP" "$STAGE/Library/Application Support/MatrixSaver/MatrixSaver.app"
cat > "$SCRIPTS/postinstall" <<'POST'
#!/bin/bash
CU=$(/usr/bin/stat -f%Su /dev/console)
UH=$(/usr/bin/dscl . -read /Users/"$CU" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
CUID=$(/usr/bin/id -u "$CU")
STAGED="/Library/Application Support/MatrixSaver/MatrixSaver.app"
DEST="$UH/Applications/MatrixSaver.app"
AX="$DEST/Contents/PlugIns/MatrixSaver.appex"
/bin/rm -rf /Applications/MatrixSaver.app 2>/dev/null || true
/bin/mkdir -p "$UH/Applications"
/bin/rm -rf "$DEST"
/usr/bin/ditto "$STAGED" "$DEST"
/usr/sbin/chown -R "$CU":staff "$UH/Applications/MatrixSaver.app"
/bin/rm -rf "/Library/Application Support/MatrixSaver" 2>/dev/null || true
/bin/launchctl asuser "$CUID" /usr/bin/pluginkit -a "$AX" 2>/dev/null || true
/usr/bin/sudo -u "$CU" /usr/bin/defaults -currentHost write com.apple.screensaver moduleDict -dict moduleName -string "MatrixSaver" path -string "$AX" type -int 0 2>/dev/null || true
/usr/bin/sudo -u "$CU" /usr/bin/defaults -currentHost write com.apple.screensaver idleTime -int 300 2>/dev/null || true
/bin/launchctl asuser "$CUID" /usr/bin/killall WallpaperAgent 2>/dev/null || true
exit 0
POST
chmod +x "$SCRIPTS/postinstall"
pkgbuild --root "$STAGE" --scripts "$SCRIPTS" --identifier io.celestialtech.MatrixSaver \
  --version "$VERSION" --install-location / --sign "$INSTID" --timestamp "$DIST/MatrixSaver-$VERSION.pkg"
echo "--- pkg built ---"; ls -la "$DIST/MatrixSaver-$VERSION.pkg"

echo "=== .dmg (drag to ~/Applications) ==="
DMGROOT="$BUILD/dmgroot"; mkdir -p "$DMGROOT"
cp -R "$APP" "$DMGROOT/MatrixSaver.app"
printf 'Drag MatrixSaver.app into your HOME > Applications (~/Applications), NOT /Applications.\n' > "$DMGROOT/INSTALL -- drag to ~Applications.txt"
hdiutil create -volname "MatrixSaver $VERSION" -srcfolder "$DMGROOT" -ov -format UDZO "$DIST/MatrixSaver-$VERSION.dmg" >/dev/null
codesign -f -s "$APPID" --timestamp "$DIST/MatrixSaver-$VERSION.dmg"
echo "BUILD_SIGN_PACKAGE_DONE v$VERSION"
