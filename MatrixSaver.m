//  MatrixSaver.m — ExtensionKit .appex screensaver.
//  Renderer selection by CONTEXT, not size (the offscreen thumbnail snapshot and every
//  on-screen host all lay out at the full 1920x1080, so a size split can't tell them apart):
//    * offscreen thumbnail snapshot -> the CG MatrixView (Monroe's Metal renders blank
//                                       offscreen; CoreGraphics draws in ANY context, so the
//                                       picker tile shows green rain)
//    * any ON-SCREEN host            -> Monroe Williams' real Metal Matrix
//  On macOS 26/27 the Settings popover preview and the real full-screen idle run are the
//  same wallpaper-agent render path at the same window level, so they can't be told apart
//  from inside the extension — both are on-screen, so both get Monroe. viewDidAppear fires
//  only for an on-screen host, never for the offscreen snapshot, which keeps the CG renderer.
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

@interface MatrixViewController : ScreenSaverViewController
@end
@implementation MatrixViewController {
    ScreenSaverView *_saver;
    BOOL _isMonroe;
    id _activity;   // NSProcessInfo activity token — keeps the render timer un-throttled
}
- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0,0,1920,1080)];
    self.view.autoresizesSubviews = NO;
}
- (ScreenSaverView *)makeMonroeWithFrame:(NSRect)f {
    NSString *base=[NSBundle bundleForClass:[self class]].bundlePath;
    NSBundle *mb=[NSBundle bundleWithPath:[base stringByAppendingPathComponent:@"Contents/Resources/Matrix.saver"]];
    NSError *e=nil; if(![mb loadAndReturnError:&e]){ MXLOG(@"Monroe load FAIL %@",e); return nil; }
    Class c=[mb principalClass];
    return c ? [[c alloc] initWithFrame:f isPreview:NO] : nil;
}
- (void)installSaver:(ScreenSaverView *)v monroe:(BOOL)monroe {
    if (_saver) { @try { [_saver stopAnimation]; } @catch(...){} [_saver removeFromSuperview]; _saver=nil; }
    if (!v) return;
    v.frame=self.view.bounds; v.autoresizingMask=NSViewNotSizable;
    [self.view addSubview:v]; _saver=v; _isMonroe=monroe;
    @try { [v startAnimation]; } @catch(...){}
}
// Default (also the offscreen thumbnail path): green CoreGraphics rain.
- (void)viewDidLayout {
    [super viewDidLayout];
    NSRect b=self.view.bounds;
    if (b.size.width<2 || b.size.height<2) return;
    if (!_saver) {
        [self installSaver:[[MatrixView alloc] initWithFrame:b isPreview:YES] monroe:NO];
        MXLOG(@"layout -> CG MatrixView (%.0fx%.0f)", b.size.width, b.size.height);
    } else {
        _saver.frame=b;
    }
}
// viewDidAppear fires for every ON-SCREEN host — the full-screen idle run AND the
// Settings popover live preview (in macOS 26/27 both are the same wallpaper-agent
// path, at the same window level, so they cannot be told apart). Both want Monroe's
// real Metal Matrix: green full-screen, visible rain in the preview. It is NEVER
// called for the offscreen thumbnail snapshot, which keeps the safe CG render (Monroe's
// Metal cannot draw into that offscreen context and would crash / go blank).
- (void)viewDidAppear {
    [super viewDidAppear];
    // On-screen: opt out of App Nap / timer coalescing. WallpaperAgent otherwise
    // lets runningboardd park this extension at AppNap timer Tier5 on battery Macs
    // (the MacBook Air), which starves the animation timer and makes the rain
    // stall to a dark freeze then redraw. A UserInitiated+LatencyCritical activity
    // assertion, held for the controller's lifetime, keeps the timer firing.
    if (!_activity) {
        _activity = [[NSProcessInfo processInfo]
            beginActivityWithOptions:(NSActivityUserInitiated | NSActivityLatencyCritical)
                              reason:@"MatrixSaver rendering"];
        MXLOG(@"began NSProcessInfo activity (anti App-Nap timer throttle)");
    }
    if (_isMonroe) return;
    NSWindow *w=self.view.window;
    MXLOG(@"viewDidAppear level=%ld -> Monroe", w?(long)w.level:-999);
    ScreenSaverView *m=[self makeMonroeWithFrame:self.view.bounds];
    if (m) { [self installSaver:m monroe:YES]; MXLOG(@"on-screen -> Monroe %@", m); }
}
- (void)dealloc {
    if (_activity) { [[NSProcessInfo processInfo] endActivity:_activity]; _activity=nil; }
}
@end
