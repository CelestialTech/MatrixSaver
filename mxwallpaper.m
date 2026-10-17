//  mxwallpaper.m — configure the macOS wallpaper Store's idle (screen-saver) Choice.
//
//  A tiny, dependency-free, UNIVERSAL command-line helper that replaces the three Python
//  plist-patchers the installer used to carry. Shipped signed inside the app bundle
//  (Contents/MacOS/mxwallpaper) and invoked by the install/uninstall postinstalls. Using a
//  compiled Foundation tool removes the installer's hard dependency on /usr/bin/python3 — which
//  on a clean Mac is a Command Line Tools shim that may be absent (and which Apple is removing).
//
//  Verbs (each edits ONLY ~/Library/Application Support/com.apple.wallpaper/Store/Index.plist,
//  as the invoking user; moduleDict is ignored on macOS 26+ — the Choice is what selects a saver):
//    activate <appex-abs-path>   set every Idle scope's Choices to our screen-saver Choice.
//    deactivate                  clear ONLY the Idle scopes whose Choice references our appex
//                                (leaves any other saver the user configured untouched).
//    check                       exit 0 iff some Idle scope references our appex, else 1.
//
//  Exit codes: 0 ok; 1 check-negative; 2 no store; 3 bad args; 4 nothing to patch; 5 write failed.
#import <Foundation/Foundation.h>

static NSString *const kMarker = @"MatrixSaver.appex";

static NSString *MXIndexPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:
            @"Library/Application Support/com.apple.wallpaper/Store/Index.plist"];
}

static NSMutableDictionary *MXLoadIndex(void) {
    NSData *d = [NSData dataWithContentsOfFile:MXIndexPath()];
    if (!d) return nil;
    id o = [NSPropertyListSerialization propertyListWithData:d
             options:NSPropertyListMutableContainersAndLeaves format:NULL error:NULL];
    return [o isKindOfClass:[NSMutableDictionary class]] ? (NSMutableDictionary *)o : nil;
}

static BOOL MXWriteIndex(id root) {
    NSData *d = [NSPropertyListSerialization dataWithPropertyList:root
                 format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    return d ? [d writeToFile:MXIndexPath() atomically:YES] : NO;
}

// Our Choice: provider com.apple.wallpaper.choice.screen-saver, Configuration = a binary-plist
// blob {module:{relative:file://<appex>}} — the shape the wallpaper store (PaperSaver) expects.
static NSDictionary *MXChoice(NSString *appex) {
    NSDictionary *mod = @{ @"module": @{ @"relative": [@"file://" stringByAppendingString:appex] } };
    NSData *cfg = [NSPropertyListSerialization dataWithPropertyList:mod
                   format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    return @{ @"Provider": @"com.apple.wallpaper.choice.screen-saver",
              @"Files": @[], @"Configuration": (cfg ?: [NSData data]) };
}

// Does any node in the tree reference our appex? Strings match directly; the Configuration is a
// nested binary-plist NSData, so scan its raw bytes for the marker (the path survives verbatim).
static BOOL MXRefs(id o) {
    if ([o isKindOfClass:[NSDictionary class]]) {
        for (id v in [(NSDictionary *)o objectEnumerator]) if (MXRefs(v)) return YES;
    } else if ([o isKindOfClass:[NSArray class]]) {
        for (id v in (NSArray *)o) if (MXRefs(v)) return YES;
    } else if ([o isKindOfClass:[NSString class]]) {
        if ([(NSString *)o containsString:kMarker]) return YES;
    } else if ([o isKindOfClass:[NSData class]]) {
        NSData *m = [kMarker dataUsingEncoding:NSUTF8StringEncoding];
        if ([(NSData *)o rangeOfData:m options:0 range:NSMakeRange(0, [(NSData *)o length])].location != NSNotFound)
            return YES;
    }
    return NO;
}

// Visit every dict that owns an Idle->Content and apply `fn` to that mutable Content.
static int gHits;
static void MXVisitIdleContent(id o, void (^fn)(NSMutableDictionary *content)) {
    if ([o isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *d = (NSMutableDictionary *)o;
        id idle = d[@"Idle"];
        if ([idle isKindOfClass:[NSDictionary class]]) {
            id content = ((NSDictionary *)idle)[@"Content"];
            if ([content isKindOfClass:[NSMutableDictionary class]]) fn((NSMutableDictionary *)content);
        }
        for (id v in [d allValues]) MXVisitIdleContent(v, fn);
    } else if ([o isKindOfClass:[NSArray class]]) {
        for (id v in (NSArray *)o) MXVisitIdleContent(v, fn);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *verb = (argc > 1) ? [NSString stringWithUTF8String:argv[1]] : @"";
        NSMutableDictionary *idx = MXLoadIndex();

        if ([verb isEqualToString:@"check"])
            return (idx && MXRefs(idx)) ? 0 : 1;

        if (!idx) return 2;

        if ([verb isEqualToString:@"activate"]) {
            if (argc < 3) return 3;
            NSString *appex = [NSString stringWithUTF8String:argv[2]];
            NSDictionary *choice = MXChoice(appex);
            gHits = 0;
            MXVisitIdleContent(idx, ^(NSMutableDictionary *content) {
                content[@"Choices"] = [NSMutableArray arrayWithObject:[choice mutableCopy]];
                gHits++;
            });
            if (gHits == 0) return 4;
            return MXWriteIndex(idx) ? 0 : 5;
        }

        if ([verb isEqualToString:@"deactivate"]) {
            MXVisitIdleContent(idx, ^(NSMutableDictionary *content) {
                id choices = content[@"Choices"];
                if ([choices isKindOfClass:[NSArray class]] && MXRefs(choices))
                    content[@"Choices"] = [NSMutableArray array];   // system falls back to default
            });
            return MXWriteIndex(idx) ? 0 : 5;
        }

        fprintf(stderr, "usage: mxwallpaper activate <appex> | deactivate | check\n");
        return 3;
    }
}
