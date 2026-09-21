//
//  MatrixView.m — classic Matrix digital-rain, hosted by the modern
//  ScreenSaver app-extension. Subclasses ScreenSaverView and uses the
//  well-supported ScreenSaverView drawing contract
//  (initWithFrame:isPreview:, animateOneFrame, drawRect:).
//
#import <ScreenSaver/ScreenSaver.h>
#import <AppKit/AppKit.h>

@interface MatrixView : ScreenSaverView
@end

@implementation MatrixView {
    NSInteger        _cols, _rows;
    CGFloat          _cell;
    NSFont          *_font;
    NSArray<NSString*> *_glyphs;   // glyph palette
    int16_t         *_grid;        // _cols*_rows, -1 = empty, else index into _glyphs
    CGFloat         *_head;        // head row (fractional) per column
    CGFloat         *_speed;       // rows/frame per column
    NSColor         *_headColor, *_bodyColor, *_dimColor;
    NSTimer         *_timer;
}

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        self.wantsLayer = YES;
        _cell = isPreview ? 8.0 : 18.0;
        _font = [NSFont fontWithName:@"Menlo-Bold" size:_cell]
              ?: [NSFont monospacedSystemFontOfSize:_cell weight:NSFontWeightBold];

        NSMutableArray *g = [NSMutableArray array];
        for (unichar c = 0xFF66; c <= 0xFF9D; c++)          // half-width katakana
            [g addObject:[NSString stringWithCharacters:&c length:1]];
        NSString *extra = @"0123456789:.=*+-<>|Z";
        for (NSUInteger i = 0; i < extra.length; i++) {
            unichar c = [extra characterAtIndex:i];
            [g addObject:[NSString stringWithCharacters:&c length:1]];
        }
        _glyphs = g;

        _headColor = [NSColor colorWithRed:0.85 green:1.00 blue:0.85 alpha:1.0];
        _bodyColor = [NSColor colorWithRed:0.20 green:1.00 blue:0.35 alpha:1.0];
        _dimColor  = [NSColor colorWithRed:0.00 green:0.50 blue:0.16 alpha:1.0];

        [self buildGrid];
    }
    return self;
}

- (void)dealloc { [self teardown]; }

- (void)teardown {
    [_timer invalidate]; _timer = nil;
    if (_grid)  { free(_grid);  _grid  = NULL; }
    if (_head)  { free(_head);  _head  = NULL; }
    if (_speed) { free(_speed); _speed = NULL; }
}

- (void)buildGrid {
    [_timer invalidate]; _timer = nil;
    if (_grid)  { free(_grid);  _grid  = NULL; }
    if (_head)  { free(_head);  _head  = NULL; }
    if (_speed) { free(_speed); _speed = NULL; }

    NSRect b = self.bounds;
    _cols = MAX(1, (NSInteger)(b.size.width  / _cell));
    _rows = MAX(1, (NSInteger)(b.size.height / _cell)) + 2;

    _grid  = malloc(sizeof(int16_t) * _cols * _rows);
    for (NSInteger i = 0; i < _cols * _rows; i++) _grid[i] = -1;
    _head  = calloc(_cols, sizeof(CGFloat));
    _speed = calloc(_cols, sizeof(CGFloat));
    for (NSInteger c = 0; c < _cols; c++) {
        _head[c]  = -(CGFloat)arc4random_uniform((uint32_t)_rows);
        _speed[c] = 0.25 + arc4random_uniform(70) / 100.0;
    }
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self buildGrid];
}

- (int16_t)rndIdx { return (int16_t)arc4random_uniform((uint32_t)_glyphs.count); }

// Drive our own timer so rendering is guaranteed regardless of how the host
// hosts us (SSENeedsAnimationTimer is left false in Info.plist).
- (void)startAnimation {
    [super startAnimation];
    if (!_timer) {
        _timer = [NSTimer timerWithTimeInterval:1.0/30.0 target:self
                                       selector:@selector(step) userInfo:nil repeats:YES];
        [[NSRunLoop currentRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
    }
}
- (void)stopAnimation { [_timer invalidate]; _timer = nil; [super stopAnimation]; }
- (void)step { [self animateOneFrame]; }

- (void)animateOneFrame {
    if (!_grid) return;
    for (NSInteger c = 0; c < _cols; c++) {
        NSInteger oldH = (NSInteger)floor(_head[c]);
        _head[c] += _speed[c];
        NSInteger newH = (NSInteger)floor(_head[c]);
        for (NSInteger r = oldH + 1; r <= newH; r++)
            if (r >= 0 && r < _rows) _grid[c * _rows + r] = [self rndIdx];
        if (_head[c] - 34 > _rows)
            _head[c] = -(CGFloat)arc4random_uniform((uint32_t)_rows);
    }
    // flicker: mutate a few live cells
    for (NSInteger k = 0; k < _cols / 3 + 1; k++) {
        NSInteger c = arc4random_uniform((uint32_t)_cols);
        NSInteger r = arc4random_uniform((uint32_t)_rows);
        if (_grid[c * _rows + r] >= 0) _grid[c * _rows + r] = [self rndIdx];
    }
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)rect {
    [[NSColor blackColor] setFill];
    NSRectFill(rect);
    if (!_grid) return;

    CGFloat H = self.bounds.size.height;
    const NSInteger trail = 24;
    for (NSInteger c = 0; c < _cols; c++) {
        NSInteger hr = (NSInteger)floor(_head[c]);
        CGFloat x = c * _cell;
        for (NSInteger t = 0; t < trail; t++) {
            NSInteger r = hr - t;
            if (r < 0 || r >= _rows) continue;
            int16_t gi = _grid[c * _rows + r];
            if (gi < 0) continue;
            NSColor *col;
            if (t == 0)      col = _headColor;
            else if (t < 8)  col = _bodyColor;
            else {
                CGFloat f = 1.0 - (CGFloat)(t - 8) / (trail - 8);
                col = [_dimColor colorWithAlphaComponent:MAX(0.05, f)];
            }
            CGFloat y = H - (r + 1) * _cell;
            [_glyphs[gi] drawAtPoint:NSMakePoint(x, y)
                      withAttributes:@{ NSFontAttributeName: _font,
                                        NSForegroundColorAttributeName: col }];
        }
    }
}
@end
