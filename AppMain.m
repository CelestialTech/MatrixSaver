//
//  AppMain.m — trivial host-app executable. Its only job is to be a valid .app
//  so LaunchServices registers the bundled screen-saver .appex. It never needs
//  to present UI.
//
#import <Cocoa/Cocoa.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    }
    return 0;
}
