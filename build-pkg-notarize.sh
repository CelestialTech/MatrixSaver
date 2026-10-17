#!/bin/bash
# Fully reproducible MatrixSaver build + packaging (macOS 14–27, arm64).
#
# Produces TWO notarized, stapled, Developer-ID-signed .pkg deliverables in dist/:
#   MatrixSaver-<v>.pkg            install / idempotent upgrade (installs to ~/Applications,
#                                  selects Matrix, forces Monroe onto Metal, locks the green
#                                  thumbnail tile, reloads WallpaperAgent).
#   MatrixSaver-Uninstall-<v>.pkg  full reversal (deregisters the appex, clears the Matrix
#                                  wallpaper Choice, unlocks + clears the locked thumbnail
#                                  cache, removes ~/Applications/MatrixSaver.app, forgets the
#                                  install receipt, reloads WallpaperAgent).
#
# Both postinstall scripts are CONTEXT-AWARE: they work when run as root (the GUI double-click /
# `installer -target /` path, via installd → launchctl asuser + sudo -u) AND when run as the user
# (the `installer -pkg … -target CurrentUserHomeDirectory` path, which needs no admin password and
# is how the DIMAS lifecycle test runs). The payload source is resolved from the installer-supplied
# destination, not a hardcoded /Library path, so a user-domain install finds its own payload.
#
# OUR code is signed with appex.entitlements (app-sandbox + disable-library-validation +
# mach-lookup for CARenderServer/CoreDisplay/ViewBridge — the set Monroe needs to load and render
# Metal under the hardened runtime). Monroe's binary is NEVER re-signed; the md5 is asserted
# unchanged across signing (re-signing it makes Metal render black).
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$SRC/build"; APP="$BUILD/MatrixSaver.app"
APPEX="$APP/Contents/PlugIns/MatrixSaver.appex"; SAVER="$APPEX/Contents/Resources/Matrix.saver"
DIST="$SRC/dist"
APPID="Developer ID Application: Rodion Nazarov (LGAQBC2VM2)"
INSTID="Developer ID Installer: Rodion Nazarov (LGAQBC2VM2)"
ENT="$SRC/appex.entitlements"
MONROE_MD5="b578c8f67450045cc653966c2992f86c"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC/Info-app.plist")"

echo "=== build app v$VERSION (arm64) ==="
rm -rf "$BUILD" "$DIST"; mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources" "$APP/Contents/MacOS" "$DIST"
clang -fobjc-arc -O2 -arch arm64 -mmacosx-version-min=14.0 \
  -framework ScreenSaver -framework AppKit -framework Foundation -framework QuartzCore -framework Metal \
  -e _NSExtensionMain "$SRC/MatrixView.m" "$SRC/MatrixSaver.m" -o "$APPEX/Contents/MacOS/MatrixSaver"
cp "$SRC/Info-appex.plist" "$APPEX/Contents/Info.plist"
cp -R "$SRC/Matrix.saver" "$APPEX/Contents/Resources/"
clang -fobjc-arc -O2 -arch arm64 -mmacosx-version-min=14.0 -framework Cocoa "$SRC/AppMain.m" -o "$APP/Contents/MacOS/MatrixSaverHost"
cp "$SRC/Info-app.plist" "$APP/Contents/Info.plist"

B=$(md5 -q "$SAVER/Contents/MacOS/"* | head -1); echo "Monroe md5 before = $B"
[ "$B" = "$MONROE_MD5" ] || { echo "FATAL: source Monroe md5 mismatch"; exit 8; }

echo "=== sign OUR code only (Monroe untouched), with appex.entitlements ==="
codesign -f -s "$APPID" --timestamp --options runtime --entitlements "$ENT" "$APPEX/Contents/MacOS/MatrixSaver"
codesign -f -s "$APPID" --timestamp --options runtime --entitlements "$ENT" "$APPEX"
codesign -f -s "$APPID" --timestamp --options runtime "$APP/Contents/MacOS/MatrixSaverHost"
codesign -f -s "$APPID" --timestamp --options runtime "$APP"
A=$(md5 -q "$SAVER/Contents/MacOS/"* | head -1); echo "Monroe md5 after  = $A"
[ "$B" = "$A" ] || { echo "FATAL_SAVER_CHANGED"; exit 9; }
codesign --verify --deep --strict "$APP" && echo "app signature OK"

# A shell fragment shared by both postinstall scripts: resolve the target user/home and define
# asuser()/runuser() that drop to that user when root, or run directly when already that user.
read -r -d '' CTX_HELPER <<'CTX' || true
if [ "$(/usr/bin/id -u)" = "0" ]; then
    CU=$(/usr/bin/stat -f%Su /dev/console)
    CUID=$(/usr/bin/id -u "$CU")
    UH=$(/usr/bin/dscl . -read /Users/"$CU" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')
    asuser()  { /bin/launchctl asuser "$CUID" /usr/bin/sudo -u "$CU" "$@"; }   # into the user's GUI session
    runuser() { /usr/bin/sudo -u "$CU" "$@"; }
    AMROOT=1
else
    CU=$(/usr/bin/whoami); CUID=$(/usr/bin/id -u); UH="$HOME"
    asuser()  { "$@"; }
    runuser() { "$@"; }
    AMROOT=0
fi
CTX

# --- install-configuration scripts (install pkg postinstall uses these) -----------------------
mk_activate_choice() {  # $1 = dest scripts dir ; selects Matrix via the wallpaper Choice
cat > "$1/activate_choice.py" <<'ACTIVATE'
import plistlib, sys, os
appex=sys.argv[1]
idx=os.path.expanduser("~/Library/Application Support/com.apple.wallpaper/Store/Index.plist")
if not os.path.exists(idx): sys.exit(0)
d=plistlib.load(open(idx,"rb"))
cfg=plistlib.dumps({"module":{"relative":"file://"+appex}},fmt=plistlib.FMT_BINARY)
choice={"Provider":"com.apple.wallpaper.choice.screen-saver","Files":[],"Configuration":cfg}
n=0
def patch(o):
    global n
    if isinstance(o,dict):
        idle=o.get("Idle")
        if isinstance(idle,dict) and isinstance(idle.get("Content"),dict):
            idle["Content"]["Choices"]=[choice]; n+=1
        for v in o.values(): patch(v)
    elif isinstance(o,list):
        for v in o: patch(v)
patch(d); plistlib.dump(d,open(idx,"wb")); print("patched",n)
ACTIVATE
}
mk_read_choice() {  # $1 = dest scripts dir ; exit 0 iff the wallpaper Choice references our appex
cat > "$1/read_choice.py" <<'READ'
import plistlib, os, sys
p=os.path.expanduser("~/Library/Application Support/com.apple.wallpaper/Store/Index.plist")
if not os.path.exists(p): sys.exit(1)
d=plistlib.load(open(p,"rb")); f=[]
def w(o):
    if isinstance(o,dict):
        [w(v) for v in o.values()]
    elif isinstance(o,list):
        [w(v) for v in o]
    elif isinstance(o,bytes) and b"MatrixSaver.appex" in o: f.append(1)
    elif isinstance(o,str) and "MatrixSaver.appex" in o: f.append(1)
w(d); sys.exit(0 if f else 1)
READ
}
mk_tile_fix() {  # $1 = dest scripts dir ; locks the green Monroe thumbnail over the swirl tile
cat > "$1/matrix_tile_fix.sh" <<'TILEFIX'
#!/bin/bash
REF="$1"
R="$HOME/Applications/MatrixSaver.app/Contents/PlugIns/MatrixSaver.appex/Contents/Resources/Matrix.saver/Contents/Resources"
GREEN="$R/thumbnail@2x.png"; [ -f "$GREEN" ] || GREEN="$R/thumbnail.png"
T="$(getconf DARWIN_USER_CACHE_DIR)com.apple.wallpaper.extension.legacy/com.apple.wallpaper.legacy.thumbnails"
[ -d "$T" ] && [ -f "$GREEN" ] || exit 0
s214=$(md5 -q "$REF/swirl_214.png" 2>/dev/null); s180=$(md5 -q "$REF/swirl_180.png" 2>/dev/null)
tmp=$(mktemp -d)
sips -z 130 214 "$GREEN" --out "$tmp/g214.png" >/dev/null 2>&1
sips -z 116 180 "$GREEN" --out "$tmp/g180.png" >/dev/null 2>&1
for f in "$T"/*.png; do
  [ -e "$f" ] || continue
  m=$(md5 -q "$f" 2>/dev/null)
  [ "$m" = "$s214" ] && { chflags nouchg "$f" 2>/dev/null; cat "$tmp/g214.png" > "$f"; chflags uchg "$f" 2>/dev/null; }
  [ "$m" = "$s180" ] && { chflags nouchg "$f" 2>/dev/null; cat "$tmp/g180.png" > "$f"; chflags uchg "$f" 2>/dev/null; }
done
rm -rf "$tmp"; exit 0
TILEFIX
}

echo "=== stage INSTALL pkg payload + scripts ==="
STAGE="$BUILD/pkgroot"; SCRIPTS="$BUILD/scripts"
mkdir -p "$STAGE/Library/Application Support/MatrixSaver" "$SCRIPTS"
ditto "$APP" "$STAGE/Library/Application Support/MatrixSaver/MatrixSaver.app"   # ditto: no ._ forks
/usr/sbin/dot_clean -m "$STAGE" 2>/dev/null || true                            # strip any AppleDouble
cp "$SRC/pkgbits/swirl_214.png" "$SRC/pkgbits/swirl_180.png" "$SCRIPTS/"
mk_activate_choice "$SCRIPTS"
mk_read_choice "$SCRIPTS"
mk_tile_fix "$SCRIPTS"

{
cat <<POSTHEAD
#!/bin/bash
SELF="\$(cd "\$(dirname "\$0")" && pwd)"
$CTX_HELPER
# Resolve the staged payload from the installer-supplied destination (\$3 volume, \$2 location),
# so a user-domain install (base=\$HOME) finds its own copy rather than a hardcoded /Library path.
STAGED=""
for BASE in "\$3" "\$2" "" ; do
  C="\$BASE/Library/Application Support/MatrixSaver/MatrixSaver.app"
  [ -d "\$C" ] && { STAGED="\$C"; break; }
done
[ -n "\$STAGED" ] || { echo "postinstall: staged payload not found"; exit 1; }
DEST="\$UH/Applications/MatrixSaver.app"; AX="\$DEST/Contents/PlugIns/MatrixSaver.appex"
/bin/rm -rf /Applications/MatrixSaver.app 2>/dev/null || true
/bin/mkdir -p "\$UH/Applications"; /bin/rm -rf "\$DEST"
/usr/bin/ditto "\$STAGED" "\$DEST"
[ "\$AMROOT" = "1" ] && /usr/sbin/chown -R "\$CU":staff "\$UH/Applications/MatrixSaver.app" || true
/bin/rm -rf "\$(dirname "\$STAGED")" 2>/dev/null || true
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
"\$LSREG" -f "\$DEST" || true
# Register the appex, RETRYING until pkd confirms it. A single pluginkit -a on a freshly
# ditto'd bundle frequently does not take inside the installer transaction (registration is
# async), which left the saver unregistered and any Choice referencing an unknown appex (then
# dropped by WallpaperAgent on reload). Re-run pluginkit -a while polling pluginkit -m, ~10s.
reg() { asuser /usr/bin/pluginkit -m -i io.celestialtech.MatrixSaver.saver 2>/dev/null | /usr/bin/grep -c Matrix; }
asuser /usr/bin/pluginkit -a "\$AX" 2>/dev/null || true
for _i in \$(/usr/bin/seq 1 20); do [ "\$(reg)" != "0" ] && break; /bin/sleep 0.5; asuser /usr/bin/pluginkit -a "\$AX" 2>/dev/null || true; done
runuser /bin/bash "\$SELF/matrix_tile_fix.sh" "\$SELF" 2>/dev/null || true
# Select Matrix and reload the agent, then VERIFY the Choice survived (a Choice whose appex was
# not yet registered gets dropped on reload); re-apply up to 5x until it sticks.
for _i in \$(/usr/bin/seq 1 5); do
  runuser /usr/bin/python3 "\$SELF/activate_choice.py" "\$AX" 2>/dev/null || true
  asuser /usr/bin/killall WallpaperAgent 2>/dev/null || true
  /bin/sleep 1
  runuser /usr/bin/python3 "\$SELF/read_choice.py" 2>/dev/null && break
done
exit 0
POSTHEAD
} > "$SCRIPTS/postinstall"
chmod +x "$SCRIPTS/postinstall" "$SCRIPTS/matrix_tile_fix.sh"

echo "=== component plist: mark the app NON-relocatable (force install path) ==="
COMP="$BUILD/component.plist"
pkgbuild --analyze --root "$STAGE" "$COMP" >/dev/null
N=$(/usr/libexec/PlistBuddy -c 'Print' "$COMP" 2>/dev/null | grep -c 'BundleIsRelocatable' || true)
i=0; while [ "$i" -lt "$N" ]; do /usr/libexec/PlistBuddy -c "Set :$i:BundleIsRelocatable false" "$COMP" 2>/dev/null || true; i=$((i+1)); done

echo "=== build + sign INSTALL .pkg ==="
INSTALL_PKG="$DIST/MatrixSaver-$VERSION.pkg"
pkgbuild --root "$STAGE" --component-plist "$COMP" --scripts "$SCRIPTS" --identifier io.celestialtech.MatrixSaver \
  --version "$VERSION" --install-location / --sign "$INSTID" --timestamp "$INSTALL_PKG"

echo "=== stage UNINSTALL pkg (nopayload: scripts only) ==="
USCRIPTS="$BUILD/uscripts"; mkdir -p "$USCRIPTS"
cat > "$USCRIPTS/deactivate_choice.py" <<'DEACT'
import plistlib, os
idx=os.path.expanduser("~/Library/Application Support/com.apple.wallpaper/Store/Index.plist")
if not os.path.exists(idx): raise SystemExit(0)
d=plistlib.load(open(idx,"rb"))
n=0
def patch(o):
    global n
    if isinstance(o,dict):
        idle=o.get("Idle")
        if isinstance(idle,dict) and isinstance(idle.get("Content"),dict) and idle["Content"].get("Choices"):
            idle["Content"]["Choices"]=[]; n+=1
        for v in o.values(): patch(v)
    elif isinstance(o,list):
        for v in o: patch(v)
patch(d); plistlib.dump(d,open(idx,"wb")); print("cleared",n)
DEACT

{
cat <<UPOSTHEAD
#!/bin/bash
SELF="\$(cd "\$(dirname "\$0")" && pwd)"
$CTX_HELPER
DEST="\$UH/Applications/MatrixSaver.app"; AX="\$DEST/Contents/PlugIns/MatrixSaver.appex"
[ -d "\$AX" ] && asuser /usr/bin/pluginkit -r "\$AX" 2>/dev/null || true
runuser /usr/bin/python3 "\$SELF/deactivate_choice.py" 2>/dev/null || true
runuser /usr/bin/defaults -currentHost delete com.apple.screensaver moduleDict 2>/dev/null || true
T="\$(runuser /usr/bin/getconf DARWIN_USER_CACHE_DIR)com.apple.wallpaper.extension.legacy/com.apple.wallpaper.legacy.thumbnails"
[ -d "\$T" ] && { /usr/bin/chflags -R nouchg "\$T" 2>/dev/null; /bin/rm -f "\$T"/*.png 2>/dev/null; } || true
/bin/rm -rf "\$DEST" /Applications/MatrixSaver.app "/Library/Application Support/MatrixSaver" 2>/dev/null || true
/usr/sbin/pkgutil --forget io.celestialtech.MatrixSaver 2>/dev/null || true
asuser /usr/bin/killall WallpaperAgent 2>/dev/null || true
exit 0
UPOSTHEAD
} > "$USCRIPTS/postinstall"
chmod +x "$USCRIPTS/postinstall"

echo "=== build + sign UNINSTALL .pkg ==="
UNINSTALL_PKG="$DIST/MatrixSaver-Uninstall-$VERSION.pkg"
pkgbuild --nopayload --scripts "$USCRIPTS" --identifier io.celestialtech.MatrixSaver.uninstall \
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
echo "PKG_DONE install=$INSTALL_PKG uninstall=$UNINSTALL_PKG"
