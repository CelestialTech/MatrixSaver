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
| `MatrixViewController` | `ScreenSaverViewController` | overrides `-loadView` to vend the view |
| `MatrixView` | `ScreenSaverView` | the rain: `initWithFrame:isPreview:`, `animateOneFrame`, `drawRect:` |

`ScreenSaverExtension` / `ScreenSaverViewController` have **no public headers** but
are **exported** by `ScreenSaver.framework` (`.tbd` lists them) — declare them
locally (`@interface X : NSObject/NSViewController`) and link `-framework ScreenSaver`.
`ScreenSaverView` IS public (`<ScreenSaver/ScreenSaver.h>`).

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
SSENeedsAnimationTimer = false   # our view drives its own NSTimer
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
- Install to **`/Applications/`** (pluginkit hard-prefers it; do NOT keep a
  second copy in `~/Applications` or DerivedData — pick ONE location).
- Register: `lsregister -f /Applications/MatrixSaver.app` then
  `pluginkit -a …/MatrixSaver.appex`. Verify:
  `pluginkit -m -i io.celestialtech.MatrixSaver.saver` → should list it, `SDK = com.apple.screensaver`.

## Activating it (wallpaper store) — programmatic, reliable

Selecting via System Settings works, but to set it headless, write the
`com.apple.wallpaper` store (`~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`).
Set every `Idle` scope (`AllSpacesAndDisplays.Idle` + each `Displays[*].Idle`) to:

```python
cfg = plistlib.dumps({"module": {"relative":
      "file:///Applications/MatrixSaver.app/Contents/PlugIns/MatrixSaver.appex"}},
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

## Reference

Apple's `Computer Name.appex` (ObjC blueprint) and the Aerial team's
`AerialScreensaver/AppexSaverMinimal` + `AerialScreensaver/PaperSaver` (the
entitlements set and the store-config shape came from these).
