//  MatrixSaver.m — ExtensionKit .appex screensaver (macOS 14–27 / Tahoe).
//
//  Renders Monroe Williams' Matrix (org.indirect.screensaver.Matrix) on its METAL renderer,
//  on every display including 2x Retina, at ~4% CPU — matching the 1x path on PaiMei.
//
//  TWO fixes, both proven on DIMAS (2560x1664 2x Retina, macOS 27.0.1), are what make this work:
//
//  (1) MONROE IS THE PRINCIPAL VIEW, not a subview.
//      WallpaperAgent hosts the .appex out-of-process (ScreenSaverViewController is an
//      NSServiceViewController / ViewBridge) and composites the controller's self.view layer
//      tree across the XPC boundary as a shared IOSurface. A plain NSView container is not
//      backed at the display's 2x scale, so a Retina panel composited a 1x surface and showed
//      BLACK. Making Monroe's Metal ScreenSaverView the controller's self.view lets ViewBridge
//      host IT directly at the real backing scale — the identical reason our CoreGraphics
//      fallback (MatrixView, layer-backed) also renders correctly on 2x.
//
//  (2) MONROE IS FORCED ONTO METAL (renderer=0) FROM INSIDE THIS PROCESS.
//      Monroe defaults to its OpenGL renderer, which on Apple-Silicon/macOS 27 is CPU-emulated
//      (~90% CPU, the flat "OpenGL" look). Metal uses the GPU (~4% CPU, the depth-shaded rain).
//      Monroe reads its "renderer" key via -[ScreenSaverDefaults defaultsForModuleWithName:],
//      which resolves to this .appex's sandbox container — so an EXTERNAL `defaults write` is
//      redirected by the sandbox and never seen. We must set it in-process, before Monroe
//      builds its view. (The sbpl entitlement Apple's own savers carry is Apple-only; adding it
//      to a third-party Developer-ID appex breaks its I/O and is NOT needed for Metal.)
//
//  Monroe's binary is NEVER re-signed (md5 b578c8f67450045cc653966c2992f86c): re-signing it
//  makes Metal render black. The build script asserts the md5 is unchanged across signing.
//
//  Thumbnail: Monroe's Metal cannot draw into the offscreen picker-snapshot context, so the
//  grid tile is a locked green PNG written into the legacy thumbnail cache by the installer
//  (matrix_tile_fix.sh) — it does not depend on any view rendering offscreen.
#import <AppKit/AppKit.h>
#import <ScreenSaver/ScreenSaver.h>
#define MXLOG(fmt, ...) NSLog(@"[MatrixSaver] " fmt, ##__VA_ARGS__)

@interface ScreenSaverExtension : NSObject
@end
@interface ScreenSaverViewController : NSViewController
// Private framework entry point: the host passes the TRUE full-resolution display frame and the
// real isPreview flag here. Overriding this (instead of -loadView) avoids the 1920x1080 hardcode
// and the Tahoe isPreview bug. From ScreenSaverPrivate.h.
- (void)loadViewForFrame:(NSRect)frame isPreview:(BOOL)isPreview;
@end
@interface MatrixView : ScreenSaverView   // our layer-backed CoreGraphics rain (MatrixView.m)
@end

@interface MatrixExtension : ScreenSaverExtension
@end
@implementation MatrixExtension
- (instancetype)init { self = [super init]; MXLOG(@"MatrixExtension init"); return self; }
@end

// ---------------------------------------------------------------------------
// Monroe hosting. Loading the Matrix.saver BUNDLE is the one expensive operation (a dylib map —
// the DYLD "unnest" memory growth). Under Tahoe the host re-instantiates the view controller at
// ~50x/min (FB19204084), so we load the bundle's principal class EXACTLY ONCE per process and
// cache it; the renderer pref is likewise written once. Each on-screen controller then builds
// its own Monroe Metal view as its principal view (GPU-cheap and resolution-independent) and
// tears it down when it leaves the screen, so churned instances cost nothing.
// ---------------------------------------------------------------------------
static Class gMonroeClass = Nil;   // Matrix.saver principal class (loaded once)
static BOOL  gMonroeTried = NO;    // bundle load attempted (success or fail), cached
static BOOL  gRendererSet = NO;    // Monroe renderer pref written (once)
static id    gActivity    = nil;   // process-global anti-App-Nap assertion

// Keep the render timer un-throttled for the whole process lifetime. WallpaperAgent otherwise
// lets runningboardd park the extension at AppNap timer Tier5 on battery Macs, starving the
// animation into a dark freeze. Held once, never per-controller.
static void MXBeginActivityOnce(void) {
    if (gActivity) return;
    gActivity = [[NSProcessInfo processInfo]
        beginActivityWithOptions:(NSActivityUserInitiated | NSActivityLatencyCritical)
                          reason:@"MatrixSaver rendering"];
    MXLOG(@"began process NSProcessInfo activity (anti App-Nap timer throttle)");
}

// Force Monroe onto its Metal renderer (0) before it builds its view. See fix (2) in the header.
static void MXConfigureMonroeRendererOnce(void) {
    if (gRendererSet) return;
    gRendererSet = YES;
    ScreenSaverDefaults *sd = [ScreenSaverDefaults defaultsForModuleWithName:@"org.indirect.screensaver.Matrix"];
    [sd setInteger:0 forKey:@"renderer"];   // 0 = Metal (1 = OpenGL)
    [sd synchronize];
    MXLOG(@"Monroe renderer pref set to Metal(0); readback=%ld", (long)[sd integerForKey:@"renderer"]);
}

// Load Monroe's principal class exactly once, caching success OR failure so a broken bundle is
// not retried on every instance. This is the DYLD map that must not repeat.
static Class MXMonroeClass(Class selfClass) {
    if (gMonroeTried) return gMonroeClass;
    gMonroeTried = YES;
    NSString *base = [NSBundle bundleForClass:selfClass].bundlePath;
    NSBundle *mb = [NSBundle bundleWithPath:
        [base stringByAppendingPathComponent:@"Contents/Resources/Matrix.saver"]];
    NSError *e = nil;
    if (![mb loadAndReturnError:&e]) { MXLOG(@"Monroe load FAIL %@", e); return Nil; }
    gMonroeClass = [mb principalClass];
    MXLOG(@"Monroe bundle loaded once; class=%@", gMonroeClass);
    return gMonroeClass;
}

@interface MatrixViewController : ScreenSaverViewController
@end
@implementation MatrixViewController {
    ScreenSaverView *_monroe;   // Monroe's Metal view (the principal view, on-screen)
    MatrixView      *_cg;       // layer-backed CoreGraphics rain — used only if Monroe won't load
    BOOL             _built;    // guard: build the view exactly once per controller
}

// Primary entry: the framework hands us the real display frame + isPreview.
- (void)loadViewForFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    if (frame.size.width < 2 || frame.size.height < 2) frame = NSMakeRect(0, 0, 1920, 1080);
    [self buildForFrame:frame isPreview:isPreview];
}
// Fallback if the framework calls plain -loadView instead.
- (void)loadView {
    NSRect frame = NSScreen.mainScreen ? NSScreen.mainScreen.frame : NSMakeRect(0, 0, 1920, 1080);
    [self buildForFrame:frame isPreview:(frame.size.width < 400)];
}

- (void)buildForFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    if (_built) return;
    _built = YES;
    MXBeginActivityOnce();
    MXConfigureMonroeRendererOnce();

    Class c = MXMonroeClass([self class]);
    if (c) {
        ScreenSaverView *m = [[c alloc] initWithFrame:frame isPreview:NO];
        if (m) {
            m.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            self.view = m; _monroe = m;
            MXLOG(@"Monroe Metal principal view %@ frame=%@", c, NSStringFromRect(frame));
            return;
        }
        MXLOG(@"Monroe alloc returned nil");
    }
    // Monroe unavailable: our layer-backed CoreGraphics rain is the principal view (renders
    // correctly on 2x via MatrixView's makeBackingLayer + contentsScale; host-driven frames).
    // ponytail: per-controller Monroe view — under Tahoe churn each deallocs with its controller
    // (ARC), so steady state is one live Metal view at ~4% CPU. If a future macOS pins churned
    // controllers in memory (accumulating Metal contexts), switch to one process-wide Monroe view
    // re-parented as the newest controller's principal view.
    MatrixView *v = [[MatrixView alloc] initWithFrame:frame isPreview:isPreview];
    v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.view = v; _cg = v;
    MXLOG(@"Monroe unavailable -> CoreGraphics fallback principal view");
}

// Start the animation only once on-screen. Monroe self-drives via its own display link; our CG
// fallback is additionally host-driven (SSENeedsAnimationTimer=true) and startAnimation calls
// super. Never called for the offscreen thumbnail snapshot, so Metal never spins up blank.
- (void)viewDidAppear {
    [super viewDidAppear];
    ScreenSaverView *v = _monroe ?: _cg;
    @try { [v startAnimation]; } @catch (...) {}
    NSWindow *w = self.view.window;
    MXLOG(@"viewDidAppear level=%ld -> %@", w ? (long)w.level : -999, _monroe ? @"Monroe Metal" : @"CoreGraphics");
}

- (void)viewDidDisappear {
    [super viewDidDisappear];
    @try { [(_monroe ?: _cg) stopAnimation]; } @catch (...) {}
}

- (void)dealloc {
    @try { [(_monroe ?: _cg) stopAnimation]; } @catch (...) {}
}
@end
