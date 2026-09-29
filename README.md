<p align="center">
  <img src="assets/hero.gif" alt="Matrix digital-rain screensaver — green katakana glyph streams flying into depth on black" width="100%">
</p>

# Matrix screensaver — modern macOS 27 App Extension (`.appex`)

A native Matrix digital-rain screensaver for macOS 14–27, built in the **modern
ExtensionKit `.appex` format** (not the legacy `.saver` plug-in). This is the
format Apple's own screensavers (Flurry, Drift, Computer Name…) use.

Why not a legacy `.saver`? On macOS 26/27 the screensaver subsystem is
aerial/wallpaper-centric; hosting a legacy `.saver` via `legacyScreenSaver.appex`
is progressively broken, and hand-writing the wallpaper-store config for a
`.saver` is fragile. A modern `.appex` is a first-class, registered screensaver.

## Architecture (three thin classes; drawing is classic ScreenSaverView)

Reverse-engineered from Apple's ObjC `Computer Name.appex`:

| Class | Base (from ScreenSaver.framework) | Role |
|---|---|---|
| `MatrixExtension` | `ScreenSaverExtension` | principal class — **empty** |
| `MatrixViewController` | `ScreenSaverViewController` | picks the renderer by context (see below); vends the view |
| `MatrixView` | `ScreenSaverView` | our CoreGraphics rain: `initWithFrame:isPreview:`, `animateOneFrame`, `drawRect:` |

`ScreenSaverExtension` / `ScreenSaverViewController` have **no public headers** but
are **exported** by `ScreenSaver.framework` (`.tbd` lists them) — declare them
locally (`@interface X : NSObject/NSViewController`) and link `-framework ScreenSaver`.
`ScreenSaverView` IS public (`<ScreenSaver/ScreenSaver.h>`).

### Renderer strategy (CoreGraphics offscreen + Monroe Metal on-screen)

The user's Matrix is **Monroe Williams' Metal** Matrix (embedded at
`Contents/Resources/Matrix.saver`, forced `renderer=0`/Metal — an OpenGL fallback
renders black). But Monroe's `MTKView` **cannot draw into the offscreen bitmap
context** the system uses to snapshot a thumbnail (it crashes / goes blank). So
`MatrixViewController` splits by *context*, not size:

- **`viewDidLayout`** → always builds our own **CoreGraphics `MatrixView`** (green,
  renders in ANY context, incl. the offscreen thumbnail snapshot — where Monroe can't).
- **`viewDidAppear`** (fires only for an ON-SCREEN host, never for the offscreen
  snapshot) → swaps to **Monroe's Metal** view.

**Non-obvious macOS 27 fact:** the Settings *popover live preview* and the *real
full-screen idle run* are the **same wallpaper-agent render path**, both hosted in a
window at `level == -2147483625`. They are indistinguishable from inside the
extension (size, level, occlusion all identical) — so you CANNOT do "CG in preview,
Monroe full-screen" by inspecting the window. Both are on-screen ⇒ both get Monroe.
Result: green Monroe full-screen + a visible rain preview (the preview reads
blue-tinted only because of the popover's translucent teal material). Only the
offscreen thumbnail snapshot stays on CoreGraphics.

## The Info.plist that makes it a screensaver (appex)

```
CFBundlePackageType = XPC!
NSExtension = {
    NSExtensionPointIdentifier = com.apple.screensaver
    NSExtensionPointVersion    = 1.0
    NSExtensionPrincipalClass  = MatrixExtension   # ObjC: no module prefix
}
ScreenSaverViewControllerClass = MatrixViewController
SSEHasConfigureSheet = false
SSENeedsAnimationTimer = true
```

## THE CRITICAL GOTCHA — entitlements + sandbox

An app extension **must be sandboxed** or `pkd` silently refuses to bind it
(`pluginkit -a` returns 0, but `pluginkit -m -i <id>` shows nothing; log:
`could not create extension point record … -10814`). Ad-hoc signing is fine for
*loading* but the appex needs these entitlements (`appex.entitlements`):

```
com.apple.security.app-sandbox = true
com.apple.security.cs.disable-library-validation = true
com.apple.security.temporary-exception.mach-lookup.global-name =
    [ com.apple.CARenderServer, com.apple.CoreDisplay.master, com.apple.ViewBridgeAuxiliary ]
```

Sign with a real **Developer ID** + hardened runtime (`-o runtime`) and the
`--entitlements` above. (Ad-hoc + these entitlements may also work locally, but
Developer ID is what was verified.) Sign the appex first, then the host app.

## Packaging & registration

- The `.appex` lives in a host app: `MatrixSaver.app/Contents/PlugIns/MatrixSaver.appex`.
- Install to **ONE** location and make sure the wallpaper store's bookmark resolves
  to it. On PaiMei this is **`~/Applications/MatrixSaver.app`** (that is the path the
  Settings picker recorded in the store). **A mismatch is silent and nasty:** a copy
  in `/Applications` registered with pluginkit while the store's `Idle` config points
  at `~/Applications` (or vice-versa) leaves a *dead reference* → the `screenSaver-`
  cache dir has an empty suffix and the picker shows a **placeholder tile**. Keep ONE
  copy; do not leave a second in `/Applications`, `~/Applications`, or DerivedData.
- Register: `lsregister -f ~/Applications/MatrixSaver.app` then
  `pluginkit -a …/MatrixSaver.appex`. Verify:
  `pluginkit -m -i io.celestialtech.MatrixSaver.saver` → should list it, `SDK = com.apple.screensaver`,
  with `Path =` the SAME location the store references.

## Activating it (wallpaper store) — programmatic, reliable

Selecting via System Settings works, but to set it headless, write the
`com.apple.wallpaper` store (`~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`).
Set every `Idle` scope (`AllSpacesAndDisplays.Idle` + each `Displays[*].Idle`) to:

```python
cfg = plistlib.dumps({"module": {"relative":
      "file:///Users/pasha/Applications/MatrixSaver.app/Contents/PlugIns/MatrixSaver.appex"}},
      fmt=plistlib.FMT_BINARY)
idle = {"Content": {"Choices": [{"Configuration": cfg, "Files": [],
        "Provider": "com.apple.wallpaper.choice.screen-saver"}]},
        "LastSet": now, "LastUse": now}
```

then `killall WallpaperAgent`. (This exact shape is from the PaperSaver library —
`{module:{relative:<file:// URL>}}` + provider `com.apple.wallpaper.choice.screen-saver`.
Same shape works for a legacy `.saver` by pointing `relative` at the `.saver`.)

Verify render: `open -a ScreenSaverEngine` (it renders the Matrix rain full-screen).

## Build

`build.sh` compiles both binaries, assembles the bundles, and installs. Sign
afterward on a machine holding the Developer ID cert (see the codesign skill):
```
codesign -f -o runtime --entitlements appex.entitlements -s "Developer ID Application: …" MatrixSaver.app/Contents/PlugIns/MatrixSaver.appex
codesign -f -o runtime -s "Developer ID Application: …" MatrixSaver.app
```

## Grid-tile thumbnail on macOS 27 — the "static thumbnail" workaround

The **large popover preview** (shown when the saver is selected) renders live and works
(see Renderer strategy). The **small grid tile** does NOT: on macOS 26/27 the picker
never renders a *third-party* saver for its tile (zero render events) — it routes the
request through the *legacy* thumbnail generator, which can't render a modern `.appex`
and emits a generic **blue-swirl placeholder**. No cache-clear, version bump, or
re-registration dislodges it, and there is no public thumbnail/poster hook in
`ScreenSaver.framework`.

Workaround = replace the picker's cached tile PNGs with a real static Matrix poster
(Monroe ships one: `Matrix.saver/Contents/Resources/thumbnail.png`, green rain) and lock
them so they can't be regenerated:

```bash
# hash-named, deterministic per saver identity; find the ones that regenerate for Matrix
T="$(getconf DARWIN_USER_CACHE_DIR)com.apple.wallpaper.extension.legacy/com.apple.wallpaper.legacy.thumbnails"
# (delete Matrix's blue-swirl PNGs, reopen picker → the 2 that come back are Matrix's:
#  one 107x65, one 90x58 — on PaiMei 3ff6ae….png and 2aaa4dff….png)
chflags nouchg "$T"/<matrix-hash>.png
cat green_107x65.png > "$T"/<107x65-hash>.png     # green thumbnail.png resized
cat green_90x58.png  > "$T"/<90x58-hash>.png      # green thumbnail.png @ 90x58
chflags uchg "$T"/<matrix-hash>.png               # lock so the picker can't overwrite
```

Reversible: `chflags nouchg` + delete → the swirl regenerates. This overwrites a system
cache and sets the immutable flag, so it trips the "irreversible local destruction" gate —
run it deliberately, not from an automated agent without the operator's OK.

## Reference

Apple's `Computer Name.appex` (ObjC blueprint) and the Aerial team's
`AerialScreensaver/AppexSaverMinimal` + `AerialScreensaver/PaperSaver` (the
entitlements set and the store-config shape came from these).
