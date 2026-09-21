//
//  MatrixSaver.m — modern macOS screen-saver app-extension wrapper.
//
//  The modern (Sonoma/Sequoia/Tahoe/27) third-party screen-saver format is an
//  ExtensionKit .appex on the "com.apple.screensaver" extension point. Its
//  principal class subclasses ScreenSaverExtension; the OS instantiates
//  ScreenSaverViewControllerClass (a ScreenSaverViewController subclass) and
//  shows its view full-screen. These two base classes are exported by
//  ScreenSaver.framework but have no public headers, so we declare them here.
//
#import <AppKit/AppKit.h>
#import <ScreenSaver/ScreenSaver.h>

// --- Private modern base classes (linked from ScreenSaver.framework) ---
@interface ScreenSaverExtension : NSObject
@end
@interface ScreenSaverViewController : NSViewController
@end

@interface MatrixView : ScreenSaverView   // implemented in MatrixView.m
@end

// --- Principal class: thin, like Flurry.FlurryExtension / ComputerNameController ---
@interface MatrixExtension : ScreenSaverExtension
@end
@implementation MatrixExtension
@end

// --- View controller: vends the ScreenSaverView, mirrors ComputerNameViewController ---
@interface MatrixViewController : ScreenSaverViewController
@end
@implementation MatrixViewController

- (void)loadView {
    NSRect frame = NSMakeRect(0, 0, 1920, 1080);
    MatrixView *v = [[MatrixView alloc] initWithFrame:frame isPreview:NO];
    v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.view = v;
    [v startAnimation];
}

@end
