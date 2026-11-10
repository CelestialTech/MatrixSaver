//  mxguardian.m — keep Matrix selected as the screen saver and restore it when macOS reverts it.
//
//  Shipped signed at Contents/MacOS/mxguardian and driven by a per-user LaunchAgent
//  (io.celestialtech.MatrixSaver.guardian) configured with RunAtLoad + WatchPaths on the wallpaper
//  Store — so it runs ONLY at login and when the Store actually changes, never on a timer. macOS
//  point-updates reset the Idle screen-saver Choice back to the default aerial ("Golden Gate") AND
//  drop the appex from pluginkit; the Wallpaper settings dialog can also clear the Choice. This
//  helper detects either and re-runs the shipped mxpostconfig.sh (re-register + re-select Matrix).
//
//  Cheap and quiet by construction: on each run it does two fast reads (is the Choice ours? is the
//  appex registered?) and, if both already hold, exits 0 immediately — no WallpaperAgent reload, no
//  work, nothing the user would notice. It is a compiled, Developer-ID-signed Mach-O (NOT a .sh) so
//  the Login Items / Background-items entry is attributed to the app's developer, not an anonymous
//  "script" row (a bare .sh LaunchAgent was explicitly rejected before — it read as noise).
//
//  Exit codes: 0 already-correct OR restore succeeded; non-zero = mxpostconfig.sh failed.
#import <Foundation/Foundation.h>
#include <mach-o/dyld.h>

static NSString *const kAppexID = @"io.celestialtech.MatrixSaver.saver";

// Run a tool to completion; capture stdout into *out (optional). Returns its exit status, or -1.
static int MXRun(NSString *path, NSArray<NSString *> *args, NSString **out) {
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:path];
    t.arguments = args ?: @[];
    NSPipe *op = [NSPipe pipe];
    t.standardOutput = op;
    t.standardError = [NSPipe pipe];
    NSError *e = nil;
    if (![t launchAndReturnError:&e]) return -1;
    NSData *d = [[op fileHandleForReading] readDataToEndOfFile];
    [t waitUntilExit];
    if (out) *out = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
    return (int)t.terminationStatus;
}

static void MXLog(NSString *s) {
    NSString *log = [NSHomeDirectory() stringByAppendingPathComponent:
                     @"Library/Logs/MatrixSaver-guardian.log"];
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [f stringFromDate:[NSDate date]], s];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:log];
    if (!fh) { [line writeToFile:log atomically:YES encoding:NSUTF8StringEncoding error:NULL]; return; }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

// Absolute path to our own executable (launchd gives an absolute Program, but resolve it the robust
// way so manual/relative invocation also works).
static NSString *MXSelfPath(void) {
    char buf[8192]; uint32_t sz = sizeof(buf);
    if (_NSGetExecutablePath(buf, &sz) == 0)
        return [[NSString stringWithUTF8String:buf] stringByStandardizingPath];
    return [[NSProcessInfo processInfo].arguments.firstObject stringByStandardizingPath];
}

int main(void) {
    @autoreleasepool {
        // .../MatrixSaver.app/Contents/MacOS/mxguardian → derive the bundle's sibling paths.
        NSString *macos    = [MXSelfPath() stringByDeletingLastPathComponent];     // …/Contents/MacOS
        NSString *contents = [macos stringByDeletingLastPathComponent];            // …/Contents
        NSString *appex    = [contents stringByAppendingPathComponent:@"PlugIns/MatrixSaver.appex"];
        NSString *cfg      = [contents stringByAppendingPathComponent:@"Resources/mxpostconfig.sh"];
        NSString *mxwp     = [macos stringByAppendingPathComponent:@"mxwallpaper"];
        NSFileManager *fm  = NSFileManager.defaultManager;

        // 1. Is Matrix the active Idle Choice? mxwallpaper `check` exits 0 iff so.
        BOOL active = [fm isExecutableFileAtPath:mxwp] && (MXRun(mxwp, @[@"check"], NULL) == 0);
        // 2. Is the appex registered with pluginkit?
        NSString *pk = @"";
        MXRun(@"/usr/bin/pluginkit", @[@"-m", @"-i", kAppexID], &pk);
        BOOL registered = ([pk rangeOfString:@"Matrix"].location != NSNotFound);

        if (active && registered) return 0;   // already correct — do nothing, say nothing

        MXLog([NSString stringWithFormat:@"revert detected (active=%d registered=%d) — restoring",
               active, registered]);
        if (![fm isExecutableFileAtPath:cfg]) { MXLog(@"FATAL: mxpostconfig.sh missing"); return 1; }
        NSString *o = @"";
        int rc = MXRun(@"/bin/bash", @[cfg, appex], &o);
        MXLog([NSString stringWithFormat:@"restore rc=%d", rc]);
        return rc;
    }
}
