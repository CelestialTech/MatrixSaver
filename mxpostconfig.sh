#!/bin/bash
# mxpostconfig.sh — register the appex and select Matrix. Shipped inside the app and run by the
# installer's postinstall (via asuser, so it runs in the console user's GUI session on a root/GUI
# install, or directly on a user-domain install). pluginkit registration of a freshly-installed
# bundle takes a few seconds and must be retried in a loop; a single attempt is not enough. This
# script does that, selects Matrix via the mxwallpaper helper, applies the green tile, and records
# the outcome in ~/Library/Logs/MatrixSaver-install.log (the installer does not fail on this step —
# a slow registration must not turn a good install into an installer error — so the log is the
# record of what happened, and re-running the installer re-runs this).
#
# Run as: mxpostconfig.sh <abs-path-to-MatrixSaver.appex>
set -u
AX="${1:-}"
RES="$(cd "$(dirname "$0")" && pwd)"            # .../MatrixSaver.app/Contents/Resources
APPPATH="$(cd "$RES/../.." && pwd)"             # .../MatrixSaver.app
HELPER="$RES/../MacOS/mxwallpaper"
APPEX_ID="io.celestialtech.MatrixSaver.saver"
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
LOG="$HOME/Library/Logs/MatrixSaver-install.log"
/bin/mkdir -p "$HOME/Library/Logs" 2>/dev/null
log(){ echo "$(/bin/date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null; }
reg(){ /usr/bin/pluginkit -m -i "$APPEX_ID" 2>/dev/null | /usr/bin/grep -c Matrix; }

[ -n "$AX" ] && [ -d "$AX" ] || { log "FATAL bad appex path: $AX"; exit 1; }
log "post-config start appex=$AX"

# 1. Register: force LaunchServices to know the bundle, then retry pluginkit -a until pkd confirms
#    (registration takes a few seconds; one attempt is not enough). ~30s budget.
"$LSREG" -f "$APPPATH" 2>/dev/null || true
/usr/bin/pluginkit -a "$AX" 2>/dev/null
i=0
while [ "$(reg)" = "0" ] && [ "$i" -lt 40 ]; do /bin/sleep 0.75; /usr/bin/pluginkit -a "$AX" 2>/dev/null; i=$((i+1)); done
if [ "$(reg)" != "0" ]; then log "registered (after ~$(( (i*3)/4 ))s)"; else log "WARN: not registered after retries; continuing"; fi

# 2. Green picker tile (best effort — the thumbnail cache may not exist yet on a fresh machine).
GREENDIR="$AX/Contents/Resources/Matrix.saver/Contents/Resources"
GREEN="$GREENDIR/thumbnail@2x.png"; [ -f "$GREEN" ] || GREEN="$GREENDIR/thumbnail.png"
T="$(/usr/bin/getconf DARWIN_USER_CACHE_DIR)com.apple.wallpaper.extension.legacy/com.apple.wallpaper.legacy.thumbnails"
if [ -d "$T" ] && [ -f "$GREEN" ]; then
  s214=$(/sbin/md5 -q "$RES/swirl_214.png" 2>/dev/null); s180=$(/sbin/md5 -q "$RES/swirl_180.png" 2>/dev/null)
  tmp=$(/usr/bin/mktemp -d)
  /usr/bin/sips -z 130 214 "$GREEN" --out "$tmp/g214.png" >/dev/null 2>&1
  /usr/bin/sips -z 116 180 "$GREEN" --out "$tmp/g180.png" >/dev/null 2>&1
  for f in "$T"/*.png; do
    [ -e "$f" ] || continue
    m=$(/sbin/md5 -q "$f" 2>/dev/null)
    [ "$m" = "$s214" ] && { /usr/bin/chflags nouchg "$f" 2>/dev/null; /bin/cat "$tmp/g214.png" > "$f"; /usr/bin/chflags uchg "$f" 2>/dev/null; }
    [ "$m" = "$s180" ] && { /usr/bin/chflags nouchg "$f" 2>/dev/null; /bin/cat "$tmp/g180.png" > "$f"; /usr/bin/chflags uchg "$f" 2>/dev/null; }
  done
  /bin/rm -rf "$tmp"; log "tile applied"
else
  log "tile skipped (cache dir or green source not present yet)"
fi

# 3. Select Matrix and VERIFY it survives a WallpaperAgent reload (retry up to 8x; each reload also
#    gives any still-pending registration more time to settle, after which the Choice sticks).
ok=0; j=0
while [ "$j" -lt 8 ]; do
  /usr/bin/pluginkit -a "$AX" 2>/dev/null
  "$HELPER" activate "$AX" 2>/dev/null
  /usr/bin/killall WallpaperAgent 2>/dev/null
  /bin/sleep 1
  if "$HELPER" check 2>/dev/null; then ok=1; break; fi
  j=$((j+1))
done
[ "$ok" = "1" ] && log "SUCCESS: Matrix selected and verified" || log "FAILED: wallpaper Choice did not take"
exit 0
