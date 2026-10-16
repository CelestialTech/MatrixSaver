//  MatrixSaver.m — ExtensionKit .appex screensaver (macOS 14–27 / Tahoe).
//
//  Renderer selection by CONTEXT, not size (the offscreen thumbnail snapshot and every
//  on-screen host all lay out at the full 1920x1080, so a size split can't tell them apart):
//    * offscreen thumbnail snapshot -> the CG MatrixView (Monroe's Metal renders blank
//                                       offscreen; CoreGraphics draws in ANY context, so the
//                                       picker tile shows green rain)
//    * any ON-SCREEN host            -> Monroe Williams' real Metal Matrix
//
//  TAHOE LIFECYCLE FIX (the reason this file was rewritten 2026-10-16):
//  On macOS 26/27 the wallpaper/screensaver host re-instantiates the view controller at
//  ~50x/min (a documented host bug — instances accumulate, FB19204084 / Aerial #1396).
//  The previous version loaded Monroe's Matrix.saver BUNDLE and built a fresh Metal view
//  inside EVERY viewDidAppear, so that host churn turned into 2500+ DYLD bundle maps and
//  Metal-context creations per hour -> 52% CPU (cpu_resource watchdog), DYLD "unnest"
//  memory growth, jetsam, and the visible black flicker on battery.
//
//  The cure: the Monroe bundle is loaded ONCE per process and exactly ONE Monroe Metal
//  view is created and cached process-wide; each on-screen controller simply RE-PARENTS
//  that single live view to itself (cheap: removeFromSuperview + addSubview, animation
//  never stopped). Host churn therefore costs nothing — the newest on-screen controller
//  owns the one Monroe view, which keeps rendering seamlessly, so there is no reload, no
//  extra Metal context, and no black frame between instances. Off-screen controllers hold
//  only a cheap CG view whose timer is stopped the moment they leave a window.
//
//  Monroe's binary is NEVER re-signed (md5 b578c8f67450045cc653966c2992f86c): re-signing
//  it makes Metal render black. The build script asserts the md5 is unchanged.
#import <AppKit/AppKit.h>
#import <ScreenSaver/ScreenSaver.h>
#define MXLOG(fmt, ...) NSLog(@"[MatrixSaver] " fmt, ##__VA_ARGS__)

@interface ScreenSaverExtension : NSObject
@end
@interface ScreenSaverViewController : NSViewController
@property (nonatomic) BOOL initialAnimationState;
@end
@interface MatrixView : ScreenSaverView   // our CG renderer (MatrixView.m)
@end

@interface MatrixExtension : ScreenSaverExtension
@end
@implementation MatrixExtension
- (instancetype)init { self=[super init]; MXLOG(@"MatrixExtension init"); return self; }
@end

// ---------------------------------------------------------------------------
// Monroe hosting. The one expensive operation is loading the Matrix.saver BUNDLE
// (a dylib map — the DYLD "unnest" memory growth + most of the CPU). Under Tahoe's
// controller churn the old code reloaded that bundle on EVERY on-screen appearance
// (85 reloads / 12 min on DIMAS). So we load the bundle's principal class exactly
// ONCE per process and cache it; each on-screen controller still gets its OWN Monroe
// Metal VIEW (GPU, resolution-independent → cheap even on the Air's 2x Retina panel,
// which is why PaiMei's 1080p Metal path was always smooth). Per-controller views —
// instead of one shared view bounced between controllers — keep every visible host
// rendering Monroe (no black preview) and are torn down when they leave the screen so
// accumulated instances cost nothing.
// ---------------------------------------------------------------------------
static Class gMonroeClass = Nil;   // Matrix.saver principal class (loaded once)
static BOOL  gMonroeTried = NO;    // bundle load attempted (success or fail), cached
static id    gActivity    = nil;   // process-global anti-App-Nap assertion

// Keep the render timer un-throttled for the whole process lifetime. WallpaperAgent
// otherwise lets runningboardd park the extension at AppNap timer Tier5 on battery
// Macs, starving the animation into a dark freeze. Held once, never per-controller.
static void MXBeginActivityOnce(void) {
    if (gActivity) return;
    gActivity = [[NSProcessInfo processInfo]
        beginActivityWithOptions:(NSActivityUserInitiated | NSActivityLatencyCritical)
                          reason:@"MatrixSaver rendering"];
    MXLOG(@"began process NSProcessInfo activity (anti App-Nap timer throttle)");
}

// Load Monroe's principal class exactly once, caching success OR failure so a broken
// bundle is not retried on every instance. This is the DYLD map that must not repeat.
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
    MatrixView      *_cg;       // cheap CoreGraphics rain — offscreen thumbnail path only
    ScreenSaverView *_monroe;   // this controller's own Monroe Metal view (on-screen)
}
- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0,0,1920,1080)];
    self.view.autoresizesSubviews = NO;
    MXBeginActivityOnce();
}

// Default (also the offscreen thumbnail path): green CoreGraphics rain. Created lazily;
// its own NSTimer drives it only while on-window (SSENeedsAnimationTimer=false). Once
// Monroe is installed (on-screen) this is gone and CG never renders full-size.
- (void)viewDidLayout {
    [super viewDidLayout];
    NSRect b = self.view.bounds;
    if (b.size.width < 2 || b.size.height < 2) return;
    if (_monroe) { _monroe.frame = b; return; }
    if (!_cg) {
        _cg = [[MatrixView alloc] initWithFrame:b isPreview:YES];
        _cg.autoresizingMask = NSViewNotSizable;
        [self.view addSubview:_cg];
        [_cg startAnimation];
        MXLOG(@"layout -> CG MatrixView (%.0fx%.0f)", b.size.width, b.size.height);
    } else {
        _cg.frame = b;
    }
}

// viewDidAppear fires for every ON-SCREEN host — the full-screen idle run AND the
// Settings popover live preview (on macOS 26/27 both are the same wallpaper-agent path
// at the same window level, so they cannot be told apart). Both want Monroe's real Metal
// Matrix. It is NEVER called for the offscreen thumbnail snapshot, which keeps the safe
// CG render (Monroe's Metal cannot draw into that offscreen context).
//
// Each on-screen controller gets its OWN Monroe view (class is cached, so no bundle
// reload) and drops the CoreGraphics fallback. GPU Metal is cheap and resolution-
// independent, so this renders Monroe on-screen on the Air's Retina panel just as it
// does on PaiMei — the CoreGraphics path never runs full-size.
- (void)viewDidAppear {
    [super viewDidAppear];
    if (_monroe) return;
    Class c = MXMonroeClass([self class]);
    if (!c) return;                 // Monroe unavailable: keep the CG fallback
    ScreenSaverView *m = [[c alloc] initWithFrame:self.view.bounds isPreview:NO];
    if (!m) { MXLOG(@"Monroe alloc returned nil"); return; }
    if (_cg) { [_cg stopAnimation]; [_cg removeFromSuperview]; _cg = nil; }
    m.frame = self.view.bounds;
    m.autoresizingMask = NSViewNotSizable;
    [self.view addSubview:m];
    @try { [m startAnimation]; } @catch(...){}
    _monroe = m;
    NSWindow *w = self.view.window;
    MXLOG(@"viewDidAppear level=%ld -> Monroe Metal (own view)", w ? (long)w.level : -999);
}

// When this controller leaves the screen, tear down its Monroe view and silence the CG
// timer so accumulated (Tahoe-churned) instances cost nothing — no lingering Metal
// contexts, no lingering CoreGraphics timers.
- (void)viewDidDisappear {
    [super viewDidDisappear];
    if (_monroe) { @try { [_monroe stopAnimation]; } @catch(...){} [_monroe removeFromSuperview]; _monroe = nil; }
    if (_cg) { [_cg stopAnimation]; }
}

- (void)dealloc {
    if (_monroe) { @try { [_monroe stopAnimation]; } @catch(...){} [_monroe removeFromSuperview]; }
    if (_cg) { [_cg stopAnimation]; [_cg removeFromSuperview]; }
}
@end
