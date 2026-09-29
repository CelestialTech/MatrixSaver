//
//  MatrixView.m — 3D "flying into the depth" Matrix rain.
//
//  Reproduces the GLMatrix-style effect (glyph streams positioned in 3D space
//  that recede into the distance, shrinking and fading into darkness) using
//  perspective-projected Core Graphics text drawing. CG renders reliably inside
//  the sandboxed screensaver host on macOS 27, unlike OpenGL (which renders
//  black) — so the classic 3D effect is ported forward natively.
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
    Stream *_streams;
    double  _cellH;      // world height of one glyph cell
    double  _zNear, _zFar;
    NSTimer *_timer;
    BOOL _preview;
}

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        _preview = isPreview;
        NSLog(@"[MatrixSaver] MatrixView initWithFrame preview=%d bounds=%@", isPreview, NSStringFromRect(frame));

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

        _cellH = 0.052;
        _zNear = 1.2;
        _zFar  = 17.0;

        _streams = calloc(NSTREAMS, sizeof(Stream));
        for (int i = 0; i < NSTREAMS; i++) [self respawn:&_streams[i] initial:YES];

        [self setAnimationTimeInterval:1.0/30.0];
    }
    return self;
}

- (void)dealloc { if (_streams) free(_streams); }

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

- (void)startAnimation { [super startAnimation]; }
- (void)stopAnimation  { [super stopAnimation]; }

- (void)animateOneFrame {
    static int _al=0; if(!_al++) NSLog(@"[MatrixSaver] animateOneFrame first");
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
    static int _dl=0; if(!_dl++) NSLog(@"[MatrixSaver] drawRect first bounds=%@", NSStringFromRect(self.bounds));
    [[NSColor blackColor] setFill];
    NSRectFill(rect);

    double W = self.bounds.size.width, H = self.bounds.size.height;
    double cx = W * 0.5, cy = H * 0.5;
    double F = W * 0.82;                        // focal length

    // draw far streams first for correct depth overlap
    int *order = malloc(sizeof(int) * NSTREAMS);
    for (int i = 0; i < NSTREAMS; i++) order[i] = i;
    for (int a = 0; a < NSTREAMS - 1; a++)      // simple insertion by z desc
        for (int b = a + 1; b < NSTREAMS; b++)
            if (_streams[order[b]].z > _streams[order[a]].z) { int t = order[a]; order[a] = order[b]; order[b] = t; }

    for (int oi = 0; oi < NSTREAMS; oi++) {
        Stream *s = &_streams[order[oi]];
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
            NSDictionary *attr = @{ NSFontAttributeName: font,
                                    NSForegroundColorAttributeName:[NSColor colorWithRed:r green:g blue:b alpha:a] };
            NSString *gl = _glyphs[s->glyph[k]];
            NSSize gs = [gl sizeWithAttributes:attr];
            [gl drawAtPoint:NSMakePoint(sx - gs.width * 0.5, sy - gs.height * 0.5) withAttributes:attr];
        }
    }
    free(order);
}
@end
