#!/bin/bash
set -euo pipefail
SRC="$HOME/Developer/CLion/MatrixSaver"
WORK="$SRC/pkgbuild_work"
APP_SRC="$HOME/Applications/MatrixSaver.app"
DIST="$SRC/dist"
INSTID="Developer ID Installer: Rodion Nazarov (LGAQBC2VM2)"
APPID="Developer ID Application: Rodion Nazarov (LGAQBC2VM2)"
VERSION="1.5"
rm -rf "$WORK"; mkdir -p "$WORK/root/Library/Application Support/MatrixSaver" "$WORK/scripts" "$DIST"
STAGED="$WORK/root/Library/Application Support/MatrixSaver/MatrixSaver.app"
ditto "$APP_SRC" "$STAGED"
chflags -R nouchg "$STAGED" 2>/dev/null || true
AX="$STAGED/Contents/PlugIns/MatrixSaver.appex"
B=$(md5 -q "$AX/Contents/Resources/Matrix.saver/Contents/MacOS/"* | head -1)
codesign -f -s "$APPID" --timestamp --options runtime --entitlements "$SRC/entitlements-appex.plist" "$AX/Contents/MacOS/MatrixSaver"
codesign -f -s "$APPID" --timestamp --options runtime --entitlements "$SRC/entitlements-appex.plist" "$AX"
codesign -f -s "$APPID" --timestamp --options runtime "$STAGED/Contents/MacOS/MatrixSaverHost"
codesign -f -s "$APPID" --timestamp --options runtime "$STAGED"
A=$(md5 -q "$AX/Contents/Resources/Matrix.saver/Contents/MacOS/"* | head -1)
echo "Matrix.saver md5 before=$B after=$A"
[ "$B" = "$A" ] || { echo FATAL_SAVER_CHANGED; exit 9; }
cp "$SRC/pkgbits/swirl_214.png" "$SRC/pkgbits/swirl_180.png" "$WORK/scripts/"

cat > "$WORK/scripts/matrix_tile_fix.sh" <<'TILEFIX'
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

cat > "$WORK/scripts/activate_choice.py" <<'ACTIVATE'
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
patch(d)
plistlib.dump(d,open(idx,"wb"))
print("patched",n)
ACTIVATE

cat > "$WORK/scripts/postinstall" <<'POST'
#!/bin/bash
SELF="$(cd "$(dirname "$0")" && pwd)"
CU=$(/usr/bin/stat -f%Su /dev/console)
UH=$(/usr/bin/dscl . -read /Users/"$CU" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
CUID=$(/usr/bin/id -u "$CU")
DEST="$UH/Applications/MatrixSaver.app"; AX="$DEST/Contents/PlugIns/MatrixSaver.appex"
# remove any noisy LaunchAgent left by older installs
/bin/launchctl asuser "$CUID" /bin/launchctl bootout gui/"$CUID"/io.celestialtech.matrixsaver.tilefix 2>/dev/null || true
/bin/rm -f "$UH/Library/LaunchAgents/io.celestialtech.matrixsaver.tilefix.plist" 2>/dev/null || true
/bin/rm -rf "$UH/Library/Application Support/MatrixSaverTileFix" 2>/dev/null || true
/bin/rm -rf /Applications/MatrixSaver.app 2>/dev/null || true
/bin/mkdir -p "$UH/Applications"; /bin/rm -rf "$DEST"
/usr/bin/ditto "/Library/Application Support/MatrixSaver/MatrixSaver.app" "$DEST"
/usr/sbin/chown -R "$CU":staff "$UH/Applications/MatrixSaver.app"
/bin/rm -rf "/Library/Application Support/MatrixSaver" 2>/dev/null || true
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
"$LSREG" -f "$DEST" || true
/bin/launchctl asuser "$CUID" /usr/bin/pluginkit -a "$AX" 2>/dev/null || true
/bin/launchctl asuser "$CUID" /usr/bin/sudo -u "$CU" /usr/bin/python3 "$SELF/activate_choice.py" "$AX" 2>/dev/null || true
/bin/launchctl asuser "$CUID" /usr/bin/sudo -u "$CU" /bin/bash "$SELF/matrix_tile_fix.sh" "$SELF" 2>/dev/null || true
/bin/launchctl asuser "$CUID" /usr/bin/killall WallpaperAgent 2>/dev/null || true
exit 0
POST
chmod +x "$WORK/scripts/postinstall" "$WORK/scripts/matrix_tile_fix.sh"
pkgbuild --root "$WORK/root" --scripts "$WORK/scripts" --identifier io.celestialtech.MatrixSaver --version "$VERSION" --install-location / --sign "$INSTID" --timestamp "$DIST/MatrixSaver-$VERSION.pkg"
echo "BUILT $DIST/MatrixSaver-$VERSION.pkg"
