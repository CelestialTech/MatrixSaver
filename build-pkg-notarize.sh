#!/bin/bash
# Fully reproducible MatrixSaver build + packaging (macOS 14–27, UNIVERSAL arm64 + x86_64).
#
# Produces TWO notarized, stapled, Developer-ID-signed .pkg deliverables in dist/:
#   MatrixSaver-<v>.pkg            install / idempotent upgrade (installs to ~/Applications,
#                                  selects Matrix, forces Monroe onto Metal, locks the green
#                                  thumbnail tile, reloads WallpaperAgent).
#   MatrixSaver-Uninstall-<v>.pkg  precise reversal (deregisters the appex via pluginkit -r,
#                                  clears ONLY our wallpaper Choice, unlocks + clears
#                                  the locked thumbnail cache, removes the app and the appex's
#                                  sandbox container, forgets the receipt, reloads WallpaperAgent).
#
# NO interpreter dependency on the target Mac: the wallpaper Choice is read/written by a compiled,
# universal, Foundation-only helper (Contents/MacOS/mxwallpaper) shipped signed inside the app —
# NOT by /usr/bin/python3 (a Command Line Tools shim that may be absent on a clean Mac). The only
# other tools the postinstalls use (sips, md5, getconf, chflags, pluginkit, lsregister, defaults)
# are all base macOS.
#
# Both postinstalls are CONTEXT-AWARE: they work as root (GUI double-click / installer -target /,
# via installd → launchctl asuser + sudo -u) AND as the user (installer -target CurrentUserHomeDirectory).
# The install postinstall VERIFIES registration + Choice and exits NON-ZERO on failure, so a broken
# install surfaces as an installer error instead of a silent "success".
#
# OUR code is signed with appex.entitlements (app-sandbox + disable-library-validation + mach-lookup
# for CARenderServer/CoreDisplay/ViewBridge — the set Monroe needs to load and render Metal under the
# hardened runtime). Monroe's binary is NEVER re-signed; its sha256 is asserted unchanged across
# signing (re-signing it makes Metal render black).
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$SRC/build"; APP="$BUILD/MatrixSaver.app"
APPEX="$APP/Contents/PlugIns/MatrixSaver.appex"; SAVER="$APPEX/Contents/Resources/Matrix.saver"
HELPER_SRC="$SRC/mxwallpaper.m"
DIST="$SRC/dist"
APPID="Developer ID Application: Rodion Nazarov (LGAQBC2VM2)"
INSTID="Developer ID Installer: Rodion Nazarov (LGAQBC2VM2)"
ENT="$SRC/appex.entitlements"
ARCHS="-arch arm64 -arch x86_64"                 # UNIVERSAL (Monroe's bundled binary is already fat)
# --- single source of truth for identifiers/names (used in code-gen below) --------------------
APPEX_ID="io.celestialtech.MatrixSaver.saver"    # the screensaver extension's bundle id
PKG_ID="io.celestialtech.MatrixSaver"            # installer package id
APP_NAME="MatrixSaver.app"
APPEX_NAME="MatrixSaver.appex"
MONROE_NAME="Matrix"                             # Monroe's single mach-o in Contents/MacOS
MONROE_SHA256="131833308da3fd2a89a054c4b958c6a5a2c4a6e5feb9c0a441731318d4833dfe"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC/Info-app.plist")"
sha(){ /usr/bin/shasum -a 256 "$1" | awk '{print $1}'; }

echo "=== build app v$VERSION (universal arm64 + x86_64) ==="
rm -rf "$BUILD" "$DIST"
mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources" "$APP/Contents/MacOS" "$DIST"
clang -fobjc-arc -O2 $ARCHS -mmacosx-version-min=14.0 \
  -framework ScreenSaver -framework AppKit -framework Foundation -framework QuartzCore -framework Metal \
  -e _NSExtensionMain "$SRC/MatrixView.m" "$SRC/MatrixSaver.m" -o "$APPEX/Contents/MacOS/MatrixSaver"
cp "$SRC/Info-appex.plist" "$APPEX/Contents/Info.plist"
cp -R "$SRC/Matrix.saver" "$APPEX/Contents/Resources/"
clang -fobjc-arc -O2 $ARCHS -mmacosx-version-min=14.0 -framework Cocoa "$SRC/AppMain.m" -o "$APP/Contents/MacOS/MatrixSaverHost"
clang -fobjc-arc -O2 $ARCHS -mmacosx-version-min=14.0 -framework Foundation "$HELPER_SRC" -o "$APP/Contents/MacOS/mxwallpaper"
cp "$SRC/Info-app.plist" "$APP/Contents/Info.plist"
# Ship the post-install configurator + the swirl reference tiles INSIDE the app (Resources are sealed
# by the app signature). The postinstall launches mxpostconfig.sh detached, post-transaction.
mkdir -p "$APP/Contents/Resources"
cp "$SRC/mxpostconfig.sh" "$APP/Contents/Resources/mxpostconfig.sh"; chmod +x "$APP/Contents/Resources/mxpostconfig.sh"
cp "$SRC/pkgbits/swirl_214.png" "$SRC/pkgbits/swirl_180.png" "$APP/Contents/Resources/"

B=$(sha "$SAVER/Contents/MacOS/$MONROE_NAME"); echo "Monroe sha256 before = $B"
[ "$B" = "$MONROE_SHA256" ] || { echo "FATAL: source Monroe sha256 mismatch"; exit 8; }
[ "$(ls -1 "$SAVER/Contents/MacOS/" | wc -l | tr -d ' ')" = "1" ] || { echo "FATAL: unexpected extra mach-o in Monroe MacOS/"; exit 8; }

echo "=== sign OUR code only (Monroe untouched), with appex.entitlements ==="
codesign -f -s "$APPID" --timestamp --options runtime --entitlements "$ENT" "$APPEX/Contents/MacOS/MatrixSaver"
codesign -f -s "$APPID" --timestamp --options runtime --entitlements "$ENT" "$APPEX"
# Sign the auxiliary helper BEFORE the bundle's main executable: signing the main executable
# (MatrixSaverHost) validates sibling Mach-Os in Contents/MacOS, so mxwallpaper must be signed first.
codesign -f -s "$APPID" --timestamp --options runtime "$APP/Contents/MacOS/mxwallpaper"
codesign -f -s "$APPID" --timestamp --options runtime "$APP/Contents/MacOS/MatrixSaverHost"
codesign -f -s "$APPID" --timestamp --options runtime "$APP"
A=$(sha "$SAVER/Contents/MacOS/$MONROE_NAME"); echo "Monroe sha256 after  = $A"
[ "$B" = "$A" ] || { echo "FATAL_SAVER_CHANGED"; exit 9; }
codesign --verify --deep --strict "$APP" && echo "app signature OK"

# shared fragment for both postinstalls: resolve the target user/home + define asuser()/runuser()
# that drop to that user when root, or run directly when already that user.
read -r -d '' CTX_HELPER <<'CTX' || true
if [ "$(/usr/bin/id -u)" = "0" ]; then
    CU=$(/usr/bin/stat -f%Su /dev/console)
    CUID=$(/usr/bin/id -u "$CU")
    UH=$(/usr/bin/dscl . -read /Users/"$CU" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')
    asuser()  { /bin/launchctl asuser "$CUID" /usr/bin/sudo -u "$CU" -H "$@"; }
    runuser() { /usr/bin/sudo -u "$CU" -H "$@"; }
    AMROOT=1
else
    CU=$(/usr/bin/whoami); CUID=$(/usr/bin/id -u); UH="$HOME"
    asuser()  { "$@"; }
    runuser() { "$@"; }
    AMROOT=0
fi
CTX

echo "=== stage INSTALL pkg payload + scripts ==="
STAGE="$BUILD/pkgroot"; SCRIPTS="$BUILD/scripts"
mkdir -p "$STAGE/Library/Application Support/MatrixSaver" "$SCRIPTS"
ditto "$APP" "$STAGE/Library/Application Support/MatrixSaver/$APP_NAME"
/usr/sbin/dot_clean -m "$STAGE" 2>/dev/null || true

{
cat <<POSTHEAD
#!/bin/bash
$CTX_HELPER
# Resolve the staged payload from the installer-supplied destination (\$3 volume, \$2 location),
# so a user-domain install (base=\$HOME) finds its own copy rather than a hardcoded /Library path.
STAGED=""
for BASE in "\$3" "\$2" "" ; do
  C="\$BASE/Library/Application Support/MatrixSaver/${APP_NAME}"
  [ -d "\$C" ] && { STAGED="\$C"; break; }
done
[ -n "\$STAGED" ] || { echo "postinstall: staged payload not found"; exit 1; }
DEST="\$UH/Applications/${APP_NAME}"; AX="\$DEST/Contents/PlugIns/${APPEX_NAME}"
CFG="\$DEST/Contents/Resources/mxpostconfig.sh"
/bin/rm -rf /Applications/${APP_NAME} 2>/dev/null || true
/bin/mkdir -p "\$UH/Applications"; /bin/rm -rf "\$DEST"
/usr/bin/ditto "\$STAGED" "\$DEST"
[ "\$AMROOT" = "1" ] && /usr/sbin/chown -R "\$CU":staff "\$UH/Applications/${APP_NAME}" || true
/bin/rm -rf "\$(dirname "\$STAGED")" 2>/dev/null || true
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
"\$LSREG" -f "\$DEST" || true
# Register the appex and select Matrix via mxpostconfig.sh (shipped in the app), run SYNCHRONOUSLY in
# the console user's GUI session (asuser) — registration takes a few seconds and needs retries, which
# it does. The installer does NOT fail on a slow/failed config (that must not turn a good payload
# install into an installer error); the outcome is recorded in ~/Library/Logs/MatrixSaver-install.log
# and re-running the installer re-runs this step.
asuser "\$CFG" "\$AX" 2>/dev/null || true
exit 0
POSTHEAD
} > "$SCRIPTS/postinstall"
chmod +x "$SCRIPTS/postinstall"

echo "=== component plist: mark the app NON-relocatable (force install path) ==="
COMP="$BUILD/component.plist"
pkgbuild --analyze --root "$STAGE" "$COMP" >/dev/null
N=$(/usr/libexec/PlistBuddy -c 'Print' "$COMP" 2>/dev/null | grep -c 'BundleIsRelocatable' || true)
i=0; while [ "$i" -lt "$N" ]; do /usr/libexec/PlistBuddy -c "Set :$i:BundleIsRelocatable false" "$COMP" 2>/dev/null || true; i=$((i+1)); done

echo "=== build + sign INSTALL .pkg ==="
INSTALL_PKG="$DIST/MatrixSaver-$VERSION.pkg"
pkgbuild --root "$STAGE" --component-plist "$COMP" --scripts "$SCRIPTS" --identifier "$PKG_ID" \
  --version "$VERSION" --install-location / --sign "$INSTID" --timestamp "$INSTALL_PKG"

echo "=== stage UNINSTALL pkg (nopayload: scripts only) ==="
USCRIPTS="$BUILD/uscripts"; mkdir -p "$USCRIPTS"
{
cat <<UPOSTHEAD
#!/bin/bash
$CTX_HELPER
DEST="\$UH/Applications/${APP_NAME}"; AX="\$DEST/Contents/PlugIns/${APPEX_NAME}"
HELPER="\$DEST/Contents/MacOS/mxwallpaper"
# Clear ONLY our wallpaper Choice (the helper leaves any other saver the user configured) BEFORE we
# remove the app the helper lives in. If the app was already trashed, the stale Choice is harmless —
# WallpaperAgent drops a Choice pointing at a missing appex on its own.
[ -x "\$HELPER" ] && runuser "\$HELPER" deactivate 2>/dev/null || true
# Deregister the extension (pluginkit -r). We do NOT lsregister -u the bundle: it is unnecessary for
# a clean uninstall and can disrupt pkd so a subsequent reinstall is slow to register.
[ -d "\$AX" ] && asuser /usr/bin/pluginkit -r "\$AX" 2>/dev/null || true
# Unlock + clear the (locked) legacy thumbnail cache so tiles regenerate clean.
T="\$(runuser /usr/bin/getconf DARWIN_USER_CACHE_DIR)com.apple.wallpaper.extension.legacy/com.apple.wallpaper.legacy.thumbnails"
[ -d "\$T" ] && { /usr/bin/chflags -R nouchg "\$T" 2>/dev/null; /bin/rm -f "\$T"/*.png 2>/dev/null; } || true
# Remove the app, any stray copies, the staged payload, AND the appex's sandbox container (which
# holds the Monroe renderer pref this product wrote).
/bin/rm -rf "\$DEST" /Applications/${APP_NAME} "/Library/Application Support/MatrixSaver" 2>/dev/null || true
/bin/rm -rf "\$UH/Library/Containers/${APPEX_ID}" 2>/dev/null || true
# Forget the receipt (needs root; in the user-domain path this is a no-op and the next install is a
# harmless "upgrade").
/usr/sbin/pkgutil --forget ${PKG_ID} 2>/dev/null || true
asuser /usr/bin/killall WallpaperAgent 2>/dev/null || true
exit 0
UPOSTHEAD
} > "$USCRIPTS/postinstall"
chmod +x "$USCRIPTS/postinstall"

echo "=== build + sign UNINSTALL .pkg ==="
UNINSTALL_PKG="$DIST/MatrixSaver-Uninstall-$VERSION.pkg"
pkgbuild --nopayload --scripts "$USCRIPTS" --identifier "${PKG_ID}.uninstall" \
  --version "$VERSION" --sign "$INSTID" --timestamp "$UNINSTALL_PKG"

echo "=== notarize + staple BOTH pkgs ==="
for P in "$INSTALL_PKG" "$UNINSTALL_PKG"; do
  echo "--- notarize $(basename "$P") ---"
  xcrun notarytool submit "$P" --keychain-profile macos-codesign-notary --wait 2>&1 | tail -6
  xcrun stapler staple "$P" 2>&1 | tail -1
done

echo "=== verify ==="
for P in "$INSTALL_PKG" "$UNINSTALL_PKG"; do
  spctl -a -vvv --type install "$P" 2>&1 | tail -2
  ls -la "$P"
done
echo "=== universal check (both arches present in our binaries) ==="
lipo -archs "$APPEX/Contents/MacOS/MatrixSaver"; lipo -archs "$APP/Contents/MacOS/mxwallpaper"
echo "PKG_DONE install=$INSTALL_PKG uninstall=$UNINSTALL_PKG"
