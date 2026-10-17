//
//  MatrixView.m — 3D "flying into the depth" Matrix rain (CoreGraphics).
//
//  Reproduces the GLMatrix-style effect (glyph streams positioned in 3D space that recede
//  into the distance, shrinking and fading into darkness) using perspective-projected Core
//  Graphics text drawing. CG renders reliably inside the sandboxed screensaver host on
//  macOS 27, unlike OpenGL (which renders black) — so the classic 3D effect is ported
//  forward natively. This is the OFFSCREEN THUMBNAIL renderer; the on-screen idle run uses
//  Monroe's Metal Matrix (see MatrixSaver.m).
//
//  Performance (rewritten 2026-10-16): the draw path previously malloc'd an index buffer
//  and ran an O(n^2) insertion sort over 240 streams on EVERY frame, and measured every
//  glyph with -sizeWithAttributes:. The depth sort is now qsort over a persistent buffer
//  and glyph metrics are cached per point size, so a frame no longer allocates or does
//  quadratic work. The view also drives its own NSTimer (Info-appex.plist sets
//  SSENeedsAnimationTimer=false) so it does not depend on the flaky framework timer and
//  it stops cleanly the moment it leaves the screen.
//
#import <ScreenSaver/ScreenSaver.h>
#import <AppKit/AppKit.h>

#define NSTREAMS 240

typedef struct {
    double x, y, z;     // world position of the stream head
    double vz;          // recede speed (into the distance)
    double vy;          // fall speed
    int    len;         // number of glyphs in the column
    int    glyph[40];   // glyph indices (index into palette)
    double mutTimer;    // for occasional glyph mutation
} Stream;

@interface MatrixView : ScreenSaverView
@end

@implementation MatrixView {
    NSArray<NSString*> *_glyphs;
    NSMutableArray<NSFont*> *_fontCache;   // index = point size
    double  *_advCache;                    // cached glyph half-size per point size
    Stream *_streams;
    int    *_order;      // persistent back-to-front draw order (no per-frame malloc)
    double  _cellH;      // world height of one glyph cell
    double  _zNear, _zFar;
    BOOL _preview;
}

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        _preview = isPreview;
        NSLog(@"[MatrixSaver] MatrixView initWithFrame preview=%d bounds=%@", isPreview, NSStringFromRect(frame));

        // HiDPI / out-of-process compositing: WallpaperAgent composites the saver via a shared
        // IOSurface, which only a LAYER-BACKED view produces. Without this the view's drawRect
        // output never crosses the process boundary and the saver is black on every display that
        // needs the surface (notably 2x Retina). See makeBackingLayer + viewDidChangeBackingProperties.
        self.wantsLayer = YES;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawDuringViewResize;

        NSMutableArray *g = [NSMutableArray array];
        for (unichar c = 0xFF66; c <= 0xFF9D; c++)             // half-width katakana
            [g addObject:[NSString stringWithCharacters:&c length:1]];
        NSString *extra = @"0123456789:.=*+<>|Z";
        for (NSUInteger i = 0; i < extra.length; i++) {
            unichar c = [extra characterAtIndex:i];
            [g addObject:[NSString stringWithCharacters:&c length:1]];
        }
        _glyphs = g;

        _fontCache = [NSMutableArray array];
        for (int i = 0; i <= 320; i++) [_fontCache addObject:(NSFont*)[NSNull null]];
        _advCache = calloc(321, sizeof(double));   // 0 = not yet measured

        _cellH = 0.052;
        _zNear = 1.2;
        _zFar  = 17.0;

        _streams = calloc(NSTREAMS, sizeof(Stream));
        _order   = calloc(NSTREAMS, sizeof(int));
        for (int i = 0; i < NSTREAMS; i++) { [self respawn:&_streams[i] initial:YES]; _order[i] = i; }

        [self setAnimationTimeInterval:1.0/30.0];
    }
    return self;
}

- (void)dealloc {
    if (_streams) free(_streams);
    if (_order)   free(_order);
    if (_advCache) free(_advCache);
}

static double frand(double a, double b) { return a + (b - a) * (arc4random_uniform(100000) / 100000.0); }

- (void)respawn:(Stream*)s initial:(BOOL)initial {
    s->x  = frand(-2.6, 2.6);
    s->y  = frand(-1.7, 2.4);
    s->z  = initial ? frand(_zNear, _zFar) : frand(_zNear, _zNear + 3.0);
    s->vz = frand(0.010, 0.055);            // recede into depth
    s->vy = frand(0.010, 0.035);            // gentle fall
    s->len = (int)frand(9, 30);
    s->mutTimer = 0;
    for (int k = 0; k < s->len; k++)
        s->glyph[k] = arc4random_uniform((uint32_t)_glyphs.count);
}

- (NSFont*)fontForSize:(int)sz {
    if (sz < 1) sz = 1; if (sz > 320) sz = 320;
    id f = _fontCache[sz];
    if (f == [NSNull null]) {
        f = [NSFont fontWithName:@"Menlo-Bold" size:sz]
          ?: [NSFont monospacedSystemFontOfSize:sz weight:NSFontWeightBold];
        _fontCache[sz] = f;
    }
    return f;
}

// Half of a representative (monospaced) glyph box at a point size, measured once per size.
// Used only to centre the glyph on its projected point; exact per-glyph metrics are
// unnecessary for a monospaced font and measuring every glyph every frame was the hot spot.
- (double)halfAdvanceForSize:(int)sz font:(NSFont*)font {
    if (sz < 1) sz = 1; if (sz > 320) sz = 320;
    if (_advCache[sz] == 0.0) {
        NSSize gs = [@"M" sizeWithAttributes:@{ NSFontAttributeName: font }];
        _advCache[sz] = gs.width * 0.5;
    }
    return _advCache[sz];
}

// Animation is HOST-DRIVEN: Info-appex.plist sets SSENeedsAnimationTimer=true, so the
// screensaver host calls -animateOneFrame on us at the frame rate. This is the canonical
// ScreenSaverView path (AppexSaverMinimal). We do NOT run our own NSTimer — a self-timer
// gated on self.window never fires in the WallpaperAgent host (the hosted view can be
// windowless), which is what left the CoreGraphics path black. Host-driven animateOneFrame
// -> setNeedsDisplay -> drawRect fills the backing layer -> IOSurface -> composited.
- (void)startAnimation { [super startAnimation]; }
- (void)stopAnimation  { [super stopAnimation]; }

// Layer-backed so the content crosses the out-of-process boundary as an IOSurface.
- (CALayer *)makeBackingLayer {
    CALayer *l = [CALayer layer];
    l.opaque = YES;
    l.backgroundColor = NSColor.blackColor.CGColor;
    l.contentsScale = [self mxBackingScale];
    return l;
}

// Backing scale without relying on self.window (nil in the hosted extension): derive it from
// the view's own backing-store conversion, falling back to the main screen's scale.
- (CGFloat)mxBackingScale {
    NSSize pt = self.bounds.size;
    if (pt.height <= 0) pt = NSMakeSize(1920, 1080);
    NSSize px = [self convertSizeToBacking:pt];
    CGFloat s = (pt.height > 0) ? (px.height / pt.height) : 1.0;
    if (s < 1.0) s = 1.0;
    if (s <= 1.0 && NSScreen.mainScreen.backingScaleFactor > 1.0) s = NSScreen.mainScreen.backingScaleFactor;
    return s;
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    self.layer.contentsScale = [self mxBackingScale];
    [self setNeedsDisplay:YES];
}
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    self.layer.contentsScale = [self mxBackingScale];
}

static int zcmp(void *ctx, const void *a, const void *b) {   // far (larger z) first
    const Stream *s = (const Stream *)ctx;
    double za = s[*(const int*)a].z, zb = s[*(const int*)b].z;
    return (za < zb) - (za > zb);
}

- (void)animateOneFrame {
    for (int i = 0; i < NSTREAMS; i++) {
        Stream *s = &_streams[i];
        s->z += s->vz;
        s->y -= s->vy;
        s->mutTimer += 1;
        if (s->mutTimer > 3) {                 // flicker a random glyph
            s->mutTimer = 0;
            s->glyph[arc4random_uniform((uint32_t)s->len)] = arc4random_uniform((uint32_t)_glyphs.count);
        }
        double bottom = s->y - s->len * _cellH;
        if (s->z > _zFar || bottom > 2.6) [self respawn:s initial:NO];
    }
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)rect {
    [[NSColor blackColor] setFill];
    NSRectFill(rect);

    double W = self.bounds.size.width, H = self.bounds.size.height;
    double cx = W * 0.5, cy = H * 0.5;
    double F = W * 0.82;                        // focal length

    qsort_r(_order, NSTREAMS, sizeof(int), _streams, zcmp);   // back-to-front, no alloc

    for (int oi = 0; oi < NSTREAMS; oi++) {
        Stream *s = &_streams[_order[oi]];
        if (s->z <= 0.15) continue;
        double depthAlpha = (_zFar - s->z) / (_zFar - _zNear);
        if (depthAlpha < 0.04) continue;
        if (depthAlpha > 1) depthAlpha = 1;

        for (int k = s->len - 1; k >= 0; k--) {
            double wy = s->y + k * _cellH;                 // k=0 head (bottom), grows upward
            double sx = cx + F * s->x / s->z;
            double sy = cy + F * wy   / s->z;              // y-up
            double size = F * _cellH / s->z;
            if (size < 2.0) break;                         // whole stream too far/small
            if (sx < -size || sx > W + size || sy < -size || sy > H + size) continue;

            double r, g, b, a;
            if (k == 0)      { r = 0.80; g = 1.00; b = 0.85; }        // bright head
            else if (k < 4)  { r = 0.30; g = 1.00; b = 0.45; }
            else             { double f = 1.0 - (double)(k - 4) / (s->len); if (f < 0.12) f = 0.12; r = 0.0; g = 0.85 * f; b = 0.22 * f; }
            a = depthAlpha * (k == 0 ? 1.0 : 0.92);

            NSFont *font = [self fontForSize:(int)(size)];
            double half = [self halfAdvanceForSize:(int)(size) font:font];
            NSDictionary *attr = @{ NSFontAttributeName: font,
                                    NSForegroundColorAttributeName:[NSColor colorWithRed:r green:g blue:b alpha:a] };
            NSString *gl = _glyphs[s->glyph[k]];
            [gl drawAtPoint:NSMakePoint(sx - half, sy - size * 0.5) withAttributes:attr];
        }
    }
}
@end
