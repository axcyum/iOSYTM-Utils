// Lock screen lyrics — merged and reworked from axcyum/LockLyrics.
// Differences from the original:
//  * uses the shared ivLyrics engine (all providers, per-song offset, translation/pronunciation)
//  * shows lines slightly early to hide the lock screen's update latency (lead time)
//  * line changes slide + crossfade over a few frames instead of jumping
//  * word-synced lyrics get a karaoke fill that advances while the line is sung

#import "IVLLockScreen.h"
#import "IVLPlaybackManager.h"
#import "IVLLyricCell.h"
#import "IVLSettings.h"
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>

static const CGFloat kCanvas = 720.0;
static const CFTimeInterval kAnimDuration = 0.32;
static const CFTimeInterval kKaraokeInterval = 0.25;

@interface IVLLockScreen ()
@property (nonatomic, assign, readwrite) BOOL updating;
@property (nonatomic, copy, readwrite) NSDictionary *originalInfo;
@end

@implementation IVLLockScreen {
    NSTimer *_timer;
    NSHashTable *_rendered;          // our MPMediaItemArtwork objects (weak)
    MPMediaItemArtwork *_artwork;    // currently shown, nil = app artwork
    NSInteger _shownIndex;
    NSString *_trackKey;

    UIImage *_background;
    NSString *_backgroundKey;
    BOOL _backgroundBusy;

    UIImage *_textFrame;             // text layer of the shown line
    UIImage *_fromText, *_toText;
    CFTimeInterval _animStart;
    BOOL _animating;
    CFTimeInterval _lastKaraoke;
    IVLKaraokeLabel *_label;
}

+ (instancetype)shared {
    static IVLLockScreen *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [self new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _rendered = [NSHashTable weakObjectsHashTable];
        _shownIndex = -2;
        _label = [[IVLKaraokeLabel alloc] initWithFrame:CGRectZero];
        _label.numberOfLines = 0;
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(reset) name:IVLTrackDidChangeNotification object:nil];
        [nc addObserver:self selector:@selector(lyricsChanged) name:IVLLyricsDidChangeNotification object:nil];
        [nc addObserver:self selector:@selector(settingsChanged:) name:IVLSettingsDidChangeNotification object:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ [self startTimer]; });
    }
    return self;
}

- (BOOL)enabled { return [IVLSettings boolForKey:IVLKeyEnabled] && [IVLSettings boolForKey:IVLKeyLockEnabled]; }

- (BOOL)isRenderedArtwork:(id)artwork {
    if (!artwork) return NO;
    @synchronized (self) { return [_rendered containsObject:artwork]; }
}

- (void)startTimer {
    [_timer invalidate];
    _timer = [NSTimer timerWithTimeInterval:1.0 / 20.0 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    _timer.tolerance = 0.01;
    [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
}

#pragma mark - Hook entry

// May be called on any thread (the app sets now-playing info from its own queues).
- (NSDictionary *)processAppInfo:(NSDictionary *)info {
    @synchronized (self) {
        if (![info isKindOfClass:[NSDictionary class]] || !info.count) {
            self.originalInfo = nil;
            _artwork = nil;
            return info;
        }
        self.originalInfo = info;
        if (_artwork && [self enabled]) {
            NSMutableDictionary *m = [info mutableCopy];
            m[MPMediaItemPropertyArtwork] = _artwork;
            return m;
        }
        return info;
    }
}

#pragma mark - State

- (void)reset {
    _shownIndex = -2;
    _textFrame = nil;
    _animating = NO;
    _background = nil;
    _backgroundKey = nil;
    [self restoreOriginal];
}

- (void)lyricsChanged {
    _shownIndex = -2;   // re-render (translation may have arrived)
    _animating = NO;
}

- (void)settingsChanged:(NSNotification *)n {
    NSString *k = n.object;
    if ([k isEqualToString:IVLKeyLockEnabled] || [k isEqualToString:IVLKeyEnabled]) {
        if (![self enabled]) [self restoreOriginal];
        _shownIndex = -2;
    } else if ([k hasPrefix:@"lock"]) {
        _shownIndex = -2;
    }
}

- (void)restoreOriginal {
    @synchronized (self) {
        if (!_artwork) return;
        _artwork = nil;
    }
    [self pushInfoWithArtwork:nil];
}

#pragma mark - Loop

- (void)tick {
    IVLPlaybackManager *m = [IVLPlaybackManager shared];
    IVLLyrics *ly = m.lyrics;
    if (![self enabled] || !ly.synced || !ly.lines.count || !self.originalInfo) {
        if (_artwork) [self restoreOriginal];
        return;
    }
    NSInteger t = [m currentTimeMs] + [IVLSettings integerForKey:IVLKeyLockLead];   // also refreshes isPlaying
    BOOL playing = [m isPlaying];
    if (!playing && !_animating && _shownIndex != -2) return;   // paused: keep the last frame

    [self ensureBackground];

    NSInteger idx = [ly indexOfLineAtTime:t];
    IVLLyricLine *line = idx >= 0 ? ly.lines[idx] : nil;
    if (line.instrumental && ![IVLSettings boolForKey:IVLKeyShowBreaks]) line = nil;

    if (idx < 0) {   // intro: show the real cover
        if (_artwork) [self restoreOriginal];
        _shownIndex = -1;
        _textFrame = nil;
        return;
    }

    CFTimeInterval now = CACurrentMediaTime();
    if (idx != _shownIndex) {
        UIImage *text = [self renderTextForIndex:idx lyrics:ly time:t];
        BOOL animate = [IVLSettings boolForKey:IVLKeyLockAnimation] && _textFrame && _shownIndex >= 0 && labs(idx - _shownIndex) == 1;
        if (animate) {
            _fromText = _textFrame;
            _toText = text;
            _animStart = now;
            _animating = YES;
        } else {
            _animating = NO;
            [self pushText:text from:nil progress:1];
        }
        _textFrame = text;
        _shownIndex = idx;
        _lastKaraoke = now;
        return;
    }

    if (_animating) {
        CGFloat p = MIN(1.0, (now - _animStart) / kAnimDuration);
        [self pushText:_toText from:_fromText progress:p];
        if (p >= 1.0) { _animating = NO; _fromText = nil; }
        return;
    }

    BOOL karaoke = line.words.count && [IVLSettings boolForKey:IVLKeyLockKaraoke] && [IVLSettings boolForKey:IVLKeyKaraoke];
    if ((karaoke || line.instrumental) && playing && now - _lastKaraoke >= kKaraokeInterval) {
        _lastKaraoke = now;
        _textFrame = [self renderTextForIndex:idx lyrics:ly time:t];
        [self pushText:_textFrame from:nil progress:1];
    }
}

#pragma mark - Output

- (void)pushText:(UIImage *)to from:(UIImage *)from progress:(CGFloat)p {
    UIImage *bg = _background ?: [self fallbackBackground];
    CGFloat e = 1 - pow(1 - p, 3);   // ease out cubic
    CGFloat shift = 70.0;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1; fmt.opaque = YES;
    UIImage *frame = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(kCanvas, kCanvas) format:fmt] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGRect r = CGRectMake(0, 0, kCanvas, kCanvas);
        [bg drawInRect:r];
        if (from) [from drawInRect:CGRectOffset(r, 0, -shift * e) blendMode:kCGBlendModeNormal alpha:1 - e];
        [to drawInRect:CGRectOffset(r, 0, from ? shift * (1 - e) : 0) blendMode:kCGBlendModeNormal alpha:from ? e : 1];
    }];
    MPMediaItemArtwork *art = [[MPMediaItemArtwork alloc] initWithBoundsSize:frame.size requestHandler:^UIImage *(CGSize size) { return frame; }];
    @synchronized (self) {
        [_rendered addObject:art];
        _artwork = art;
    }
    [self pushInfoWithArtwork:art];
}

- (void)pushInfoWithArtwork:(MPMediaItemArtwork *)art {
    NSDictionary *base;
    @synchronized (self) { base = self.originalInfo; }
    if (!base) return;
    NSMutableDictionary *d = [base mutableCopy];
    if (art) d[MPMediaItemPropertyArtwork] = art;
    // keep the scrubber where the player really is
    NSInteger raw = [[IVLPlaybackManager shared] rawTimeMs];
    if (raw > 0) d[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(raw / 1000.0);
    self.updating = YES;
    @try { [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = d; }
    @catch (__unused NSException *e) {}
    self.updating = NO;
}

#pragma mark - Rendering

- (UIImage *)fallbackBackground {
    static UIImage *img;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
        fmt.scale = 1; fmt.opaque = YES;
        img = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(kCanvas, kCanvas) format:fmt] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            NSArray *colors = @[(__bridge id)[UIColor colorWithRed:0.14 green:0.16 blue:0.22 alpha:1].CGColor,
                                (__bridge id)[UIColor colorWithRed:0.04 green:0.05 blue:0.07 alpha:1].CGColor];
            CGGradientRef g = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)colors, NULL);
            CGContextDrawLinearGradient(ctx.CGContext, g, CGPointZero, CGPointMake(kCanvas, kCanvas), 0);
            CGGradientRelease(g);
            CGColorSpaceRelease(cs);
        }];
    });
    return img;
}

- (void)ensureBackground {
    IVLTrack *track = [IVLPlaybackManager shared].track;
    NSString *key = track.videoID ?: @"";
    if ([key isEqualToString:_backgroundKey] || _backgroundBusy) return;

    UIImage *source = [track.artworkImage isKindOfClass:[UIImage class]] ? track.artworkImage : nil;
    id art = self.originalInfo[MPMediaItemPropertyArtwork];
    if (!source && [art isKindOfClass:[MPMediaItemArtwork class]] && ![self isRenderedArtwork:art]) {
        @try { source = [(MPMediaItemArtwork *)art imageWithSize:CGSizeMake(kCanvas, kCanvas)]; } @catch (__unused NSException *e) {}
    }
    if (!source) return;   // try again next tick (artwork may arrive later)

    _backgroundBusy = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        UIImage *bg = [IVLLockScreen blurredBackground:source];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_backgroundBusy = NO;
            if (![[IVLPlaybackManager shared].track.videoID ?: @"" isEqualToString:key]) return;
            self->_background = bg;
            self->_backgroundKey = key;
            self->_shownIndex = -2;   // redraw on the new background
        });
    });
}

+ (UIImage *)blurredBackground:(UIImage *)source {
    CGSize size = CGSizeMake(kCanvas, kCanvas);
    CGRect rect = CGRectMake(0, 0, kCanvas, kCanvas);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1; fmt.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
    UIImage *filled = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGFloat s = MAX(kCanvas / MAX(1, source.size.width), kCanvas / MAX(1, source.size.height));
        CGSize d = CGSizeMake(source.size.width * s, source.size.height * s);
        [source drawInRect:CGRectMake((kCanvas - d.width) / 2, (kCanvas - d.height) / 2, d.width, d.height)];
    }];
    UIImage *blurred = filled;
    @try {
        static CIContext *ci;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ ci = [CIContext contextWithOptions:@{ kCIContextCacheIntermediates: @NO }]; });
        CIImage *input = [[CIImage alloc] initWithImage:filled];
        CIImage *clamped = [input imageByClampingToExtent];
        CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
        [blur setValue:clamped forKey:kCIInputImageKey];
        [blur setValue:@26 forKey:kCIInputRadiusKey];
        CGImageRef cg = [ci createCGImage:blur.outputImage fromRect:rect];
        if (cg) { blurred = [UIImage imageWithCGImage:cg]; CGImageRelease(cg); }
    } @catch (__unused NSException *e) {}
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [blurred drawInRect:rect];
        [[UIColor colorWithWhite:0 alpha:0.5] setFill];
        UIRectFillUsingBlendMode(rect, kCGBlendModeNormal);
    }];
}

static NSDictionary *IVLLockAttrs(UIFont *font, UIColor *color) {
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = NSTextAlignmentCenter;
    ps.lineBreakMode = NSLineBreakByWordWrapping;
    ps.lineSpacing = 4;
    NSShadow *sh = [NSShadow new];
    sh.shadowColor = [UIColor colorWithWhite:0 alpha:0.6];
    sh.shadowOffset = CGSizeMake(0, 2);
    sh.shadowBlurRadius = 6;
    return @{ NSFontAttributeName: font, NSForegroundColorAttributeName: color, NSParagraphStyleAttributeName: ps, NSShadowAttributeName: sh };
}

static CGFloat IVLMeasure(NSString *s, NSDictionary *attrs, CGFloat width) {
    if (!s.length) return 0;
    return ceil([s boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX) options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading attributes:attrs context:nil].size.height);
}

/// Transparent text layer: previous line, current line (+ pronunciation / translation), next line.
- (UIImage *)renderTextForIndex:(NSInteger)idx lyrics:(IVLLyrics *)ly time:(NSInteger)t {
    const CGFloat pad = 52, width = kCanvas - pad * 2, gap = 26;
    IVLLyricLine *cur = ly.lines[idx];
    BOOL showExtra = [IVLSettings boolForKey:IVLKeyLockTranslation];

    // previous / next real lines (skip breaks)
    NSString *prev = nil, *next = nil;
    for (NSInteger i = idx - 1; i >= 0; i--) if (!ly.lines[i].instrumental) { prev = ly.lines[i].text; break; }
    for (NSInteger i = idx + 1; i < (NSInteger)ly.lines.count; i++) if (!ly.lines[i].instrumental) { next = ly.lines[i].text; break; }

    NSDictionary *side = IVLLockAttrs([UIFont systemFontOfSize:27 weight:UIFontWeightSemibold], [UIColor colorWithWhite:1 alpha:0.42]);
    NSDictionary *extra = IVLLockAttrs([UIFont systemFontOfSize:25 weight:UIFontWeightMedium], [UIColor colorWithWhite:1 alpha:0.78]);

    // current line: shrink until it fits
    NSDictionary *main = nil;
    CGFloat mainH = 0;
    NSString *curText = cur.instrumental ? @"" : cur.text;
    for (NSNumber *size in @[@46, @40, @34, @30]) {
        main = IVLLockAttrs([UIFont systemFontOfSize:size.doubleValue weight:UIFontWeightBold], UIColor.whiteColor);
        mainH = IVLMeasure(curText, main, width);
        if (mainH <= 250) break;
    }
    mainH = MIN(mainH, 300);
    NSMutableArray<NSString *> *extras = [NSMutableArray array];
    if (showExtra && cur.pronunciation.length) [extras addObject:cur.pronunciation];
    if (showExtra && cur.translation.length) [extras addObject:cur.translation];
    NSString *extraText = [extras componentsJoinedByString:@"\n"];
    CGFloat extraH = MIN(IVLMeasure(extraText, extra, width), 130);

    CGFloat blockH = cur.instrumental ? 40 : mainH + (extraH ? 10 + extraH : 0);
    CGFloat top = floor((kCanvas - blockH) / 2);

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1; fmt.opaque = NO;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(kCanvas, kCanvas) format:fmt] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        if (cur.instrumental) {
            CGFloat span = MAX(1, cur.endMs - cur.startMs);
            CGFloat p = MIN(1, MAX(0, (t - cur.startMs) / span));
            for (int i = 0; i < 3; i++) {
                CGFloat local = MIN(1, MAX(0, p * 3 - i));
                [[UIColor colorWithWhite:1 alpha:0.3 + 0.7 * local] setFill];
                CGFloat d = 22, x = kCanvas / 2 - 50 + i * 40 - d / 2;
                [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(x, kCanvas / 2 - d / 2, d, d)] fill];
            }
        } else {
            // karaoke-capable main line
            NSMutableAttributedString *as = [[NSMutableAttributedString alloc] initWithString:curText attributes:main];
            [as removeAttribute:NSShadowAttributeName range:NSMakeRange(0, as.length)];
            self->_label.attributedText = as;
            self->_label.frame = CGRectMake(0, 0, width, mainH);
            BOOL karaoke = cur.words.count && [IVLSettings boolForKey:IVLKeyLockKaraoke] && [IVLSettings boolForKey:IVLKeyKaraoke];
            self->_label.words = karaoke ? cur.words : nil;
            self->_label.dimColor = [UIColor colorWithWhite:1 alpha:0.45];
            self->_label.brightColor = UIColor.whiteColor;
            self->_label.karaokeActive = karaoke;
            self->_label.timeMs = t;
            CGContextSaveGState(ctx.CGContext);
            CGContextSetShadowWithColor(ctx.CGContext, CGSizeMake(0, 2), 6, [UIColor colorWithWhite:0 alpha:0.6].CGColor);
            CGContextTranslateCTM(ctx.CGContext, pad, top);
            [self->_label drawTextInRect:CGRectMake(0, 0, width, mainH)];
            CGContextRestoreGState(ctx.CGContext);
            if (extraH) {
                [extraText drawWithRect:CGRectMake(pad, top + mainH + 10, width, extraH)
                                options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine attributes:extra context:nil];
            }
        }
        if (prev.length) {
            CGFloat h = MIN(IVLMeasure(prev, side, width), MAX(0, top - gap - 30));
            if (h >= 30) [prev drawWithRect:CGRectMake(pad, top - gap - h, width, h)
                                    options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine attributes:side context:nil];
        }
        if (next.length) {
            CGFloat y = top + blockH + gap;
            CGFloat h = MIN(IVLMeasure(next, side, width), MAX(0, kCanvas - 30 - y));
            if (h >= 30) [next drawWithRect:CGRectMake(pad, y, width, h)
                                    options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine attributes:side context:nil];
        }
    }];
}

@end
