// Apple Music (v27.0) immersive "Now Playing", built to the design specification:
//
//  1. Hero canvas 0–58%: the artwork full-bleed behind the status bar, no radius, no frame.
//     (A wide video keeps its own 16:9 shape across the full width instead of being cropped.)
//  2. Optical dissolve 48–65%: a progressive Gaussian blur (0 → 60) and a mesh of the artwork's
//     own colours; no hard edge, no flat black gradient. The blurred artwork keeps bleeding
//     behind the title (ambient colour bleed).
//  3. Control deck 58–100%, 26pt side padding: title/artist + ☆ •••, knobless scrubber with
//     tabular timestamps (-m:ss), frameless transport with 28–36pt margins, knobless volume bar,
//     footer with lyrics · AirPlay · queue (+ state micro badge).
//  Colour: white only, hierarchy by opacity (0.92 / 0.62 / 0.48 / inactive 0.22). No accent.
//  Sliders: 6pt capsules without a thumb, swelling to 11pt while touched (spring).
//  Buttons: no circle, no border; press = scale 0.88 spring + soft translucent glow.

#import "IVLPlayerPanel.h"
#import "IVLPlaybackManager.h"
#import "IVLRemoteControl.h"
#import "IVLExtras.h"
#import "IVLSettings.h"
#import "IVLLocalization.h"
#import <AVKit/AVKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <CoreImage/CoreImage.h>

// opacity tokens
#define IVLPrimary   [UIColor colorWithWhite:1 alpha:0.92]
#define IVLSecondary [UIColor colorWithWhite:1 alpha:0.62]
#define IVLTertiary  [UIColor colorWithWhite:1 alpha:0.48]
#define IVLInactive  [UIColor colorWithWhite:1 alpha:0.22]

static const CGFloat kPad = 26;

static NSString *IVLClock(double s) {
    long v = (long)MAX(0, floor(s));
    return [NSString stringWithFormat:@"%ld:%02ld", v / 60, v % 60];
}

#pragma mark - Knobless capsule bar

@interface IVLCapsuleBar : UIControl
@property (nonatomic) CGFloat value;   // 0...1
@property (nonatomic, readonly) BOOL dragging;
@end

@implementation IVLCapsuleBar {
    UIView *_track, *_fill;
    CGFloat _h;
    BOOL _dragging;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _h = 6;
        _track = [UIView new];
        _track.backgroundColor = IVLInactive;
        _track.clipsToBounds = YES;
        _track.userInteractionEnabled = NO;
        _fill = [UIView new];
        _fill.backgroundColor = IVLPrimary;
        [_track addSubview:_fill];
        [self addSubview:_track];
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitAdjustable;
    }
    return self;
}

- (BOOL)dragging { return _dragging; }
- (void)setValue:(CGFloat)v { _value = MIN(1, MAX(0, v)); [self setNeedsLayout]; }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    _track.frame = CGRectMake(0, (self.bounds.size.height - _h) / 2, w, _h);
    _track.layer.cornerRadius = _h / 2;
    _fill.frame = CGRectMake(0, 0, w * _value, _h);
}

- (void)swell:(BOOL)on {
    _h = on ? 11 : 6;
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.55 initialSpringVelocity:0 options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState animations:^{
        [self layoutSubviews];
    } completion:nil];
}

- (void)track:(UITouch *)t { self.value = [t locationInView:self].x / MAX(1, self.bounds.size.width); [self sendActionsForControlEvents:UIControlEventValueChanged]; }
- (BOOL)beginTrackingWithTouch:(UITouch *)t withEvent:(UIEvent *)e { _dragging = YES; [self swell:YES]; [self track:t]; return YES; }
- (BOOL)continueTrackingWithTouch:(UITouch *)t withEvent:(UIEvent *)e { [self track:t]; return YES; }
- (void)endTrackingWithTouch:(UITouch *)t withEvent:(UIEvent *)e { _dragging = NO; [self swell:NO]; [self sendActionsForControlEvents:UIControlEventTouchUpInside]; }
- (void)cancelTrackingWithEvent:(UIEvent *)e { _dragging = NO; [self swell:NO]; [self sendActionsForControlEvents:UIControlEventTouchUpInside]; }
- (void)accessibilityIncrement { self.value += 0.05; [self sendActionsForControlEvents:UIControlEventTouchUpInside]; }
- (void)accessibilityDecrement { self.value -= 0.05; [self sendActionsForControlEvents:UIControlEventTouchUpInside]; }

@end

#pragma mark - Frameless button (scale 0.88 + soft glow)

@interface IVLGlyphButton : UIButton
@end

@implementation IVLGlyphButton {
    UIView *_glow;
}

+ (instancetype)glyph:(NSString *)symbol size:(CGFloat)pt color:(UIColor *)color {
    IVLGlyphButton *b = [self buttonWithType:UIButtonTypeCustom];
    [b setSymbol:symbol size:pt];
    b.tintColor = color;
    b.adjustsImageWhenHighlighted = NO;
    b->_glow = [UIView new];
    b->_glow.userInteractionEnabled = NO;
    b->_glow.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    b->_glow.alpha = 0;
    [b insertSubview:b->_glow atIndex:0];
    return b;
}

- (void)setSymbol:(NSString *)symbol size:(CGFloat)pt {
    UIImage *img = [[UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:pt weight:UIImageSymbolWeightBold]]
                    imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    [self setImage:img forState:UIControlStateNormal];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat d = MIN(self.bounds.size.width, self.bounds.size.height);
    _glow.frame = CGRectMake((self.bounds.size.width - d) / 2, (self.bounds.size.height - d) / 2, d, d);
    _glow.layer.cornerRadius = d / 2;
}

- (void)setHighlighted:(BOOL)h {
    [super setHighlighted:h];
    [UIView animateWithDuration:h ? 0.12 : 0.45 delay:0 usingSpringWithDamping:h ? 1 : 0.55 initialSpringVelocity:0 options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState animations:^{
        self.imageView.transform = h ? CGAffineTransformMakeScale(0.88, 0.88) : CGAffineTransformIdentity;
        self->_glow.alpha = h ? 1 : 0;
    } completion:nil];
}

@end

#pragma mark - Panel

@implementation IVLPlayerPanel {
    // atmosphere
    CAGradientLayer *_mesh;
    UIImageView *_hero, *_heroBlur;
    CAGradientLayer *_heroMask, *_blurMask;
    UIView *_grabber;
    // deck
    UILabel *_title, *_artist, *_lyric, *_elapsed, *_remaining;
    IVLGlyphButton *_star, *_more, *_prev, *_play, *_next, *_lyricsBtn, *_queueBtn;
    UIView *_badge;
    AVRoutePickerView *_airplay;
    IVLCapsuleBar *_seek, *_volume;
    UIImageView *_volLow, *_volHigh;
    MPVolumeView *_systemVolume;
    UISlider *_systemSlider;
    // state
    CGFloat _aspect;
    BOOL _shownPlaying;
    NSString *_imageKey;
    UIPanGestureRecognizer *_pan;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _aspect = 1;
        _shownPlaying = YES;
        self.backgroundColor = UIColor.blackColor;
        self.clipsToBounds = YES;

        _mesh = [CAGradientLayer layer];
        _mesh.colors = @[(id)[UIColor colorWithWhite:0.18 alpha:1].CGColor, (id)[UIColor colorWithWhite:0.08 alpha:1].CGColor];
        [self.layer addSublayer:_mesh];

        _hero = [UIImageView new];
        _hero.contentMode = UIViewContentModeScaleAspectFill;
        _hero.clipsToBounds = YES;
        _heroMask = [CAGradientLayer layer];
        _hero.layer.mask = _heroMask;
        [self addSubview:_hero];

        _heroBlur = [UIImageView new];
        _heroBlur.contentMode = UIViewContentModeScaleAspectFill;
        _heroBlur.clipsToBounds = YES;
        _blurMask = [CAGradientLayer layer];
        _heroBlur.layer.mask = _blurMask;
        [self addSubview:_heroBlur];

        _grabber = [UIView new];
        _grabber.backgroundColor = [UIColor colorWithWhite:1 alpha:0.35];
        _grabber.layer.cornerRadius = 2;
        [self addSubview:_grabber];

        _title = [UILabel new];
        _artist = [UILabel new];
        _artist.font = [UIFont systemFontOfSize:18.5 weight:UIFontWeightRegular];
        _artist.textColor = IVLSecondary;
        _lyric = [UILabel new];
        _lyric.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _lyric.textColor = IVLSecondary;
        _lyric.userInteractionEnabled = YES;
        [_lyric addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(lyricsTapped)]];
        _elapsed = [UILabel new];
        _remaining = [UILabel new];
        for (UILabel *l in @[_elapsed, _remaining]) {
            l.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];   // tabular-nums
            l.textColor = IVLTertiary;
        }
        _remaining.textAlignment = NSTextAlignmentRight;

        _star = [IVLGlyphButton glyph:@"star" size:17 color:IVLSecondary];
        [_star addTarget:self action:@selector(starTapped) forControlEvents:UIControlEventTouchUpInside];
        _more = [IVLGlyphButton glyph:@"ellipsis" size:17 color:IVLSecondary];
        _more.showsMenuAsPrimaryAction = YES;

        _seek = [IVLCapsuleBar new];
        [_seek addTarget:self action:@selector(seekMoved) forControlEvents:UIControlEventValueChanged];
        [_seek addTarget:self action:@selector(seekEnded) forControlEvents:UIControlEventTouchUpInside];

        _prev = [IVLGlyphButton glyph:@"backward.fill" size:30 color:IVLPrimary];
        _play = [IVLGlyphButton glyph:@"pause.fill" size:44 color:IVLPrimary];
        _next = [IVLGlyphButton glyph:@"forward.fill" size:30 color:IVLPrimary];
        [_prev addTarget:self action:@selector(prevTapped) forControlEvents:UIControlEventTouchUpInside];
        [_play addTarget:self action:@selector(playTapped) forControlEvents:UIControlEventTouchUpInside];
        [_next addTarget:self action:@selector(nextTapped) forControlEvents:UIControlEventTouchUpInside];

        _volume = [IVLCapsuleBar new];
        [_volume addTarget:self action:@selector(volumeMoved) forControlEvents:UIControlEventValueChanged];
        UIImageSymbolConfiguration *small = [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightSemibold];
        _volLow = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"speaker.fill" withConfiguration:small]];
        _volHigh = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"speaker.wave.3.fill" withConfiguration:small]];
        for (UIImageView *v in @[_volLow, _volHigh]) { v.tintColor = IVLTertiary; v.contentMode = UIViewContentModeCenter; }
        // the system volume is driven through an MPVolumeView kept in the hierarchy but off-screen
        _systemVolume = [[MPVolumeView alloc] initWithFrame:CGRectMake(-2000, -2000, 10, 10)];
        _systemVolume.alpha = 0.01;
        for (UIView *v in _systemVolume.subviews) if ([v isKindOfClass:[UISlider class]]) _systemSlider = (UISlider *)v;
        [self addSubview:_systemVolume];
        [[AVAudioSession sharedInstance] addObserver:self forKeyPath:@"outputVolume" options:NSKeyValueObservingOptionNew context:NULL];

        _lyricsBtn = [IVLGlyphButton glyph:@"quote.bubble" size:20 color:IVLTertiary];
        [_lyricsBtn addTarget:self action:@selector(lyricsTapped) forControlEvents:UIControlEventTouchUpInside];
        _airplay = [AVRoutePickerView new];
        _airplay.tintColor = IVLTertiary;
        _airplay.activeTintColor = IVLPrimary;
        _airplay.prioritizesVideoDevices = NO;
        _queueBtn = [IVLGlyphButton glyph:@"list.bullet" size:20 color:IVLTertiary];
        [_queueBtn addTarget:self action:@selector(queueTapped) forControlEvents:UIControlEventTouchUpInside];
        _badge = [UIView new];
        _badge.backgroundColor = IVLPrimary;
        _badge.layer.cornerRadius = 3;
        _badge.hidden = YES;

        for (UIView *v in @[_title, _artist, _star, _more, _lyric, _seek, _elapsed, _remaining, _prev, _play, _next,
                            _volLow, _volume, _volHigh, _lyricsBtn, _airplay, _queueBtn, _badge]) [self addSubview:v];

        _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
        [self addGestureRecognizer:_pan];
        [self syncVolume];
    }
    return self;
}

- (void)dealloc {
    @try { [[AVAudioSession sharedInstance] removeObserver:self forKeyPath:@"outputVolume"]; } @catch (__unused NSException *e) {}
}

- (void)setMoreMenu:(UIMenu *)menu { _moreMenu = menu; _more.menu = menu; }

#pragma mark Atmosphere

- (void)setArtwork:(UIImage *)image {
    NSString *key = image ? [NSString stringWithFormat:@"%p", image] : @"";
    if ([key isEqualToString:_imageKey]) return;
    _imageKey = key;
    _hero.image = image;
    CGFloat a = (image && image.size.height > 0) ? image.size.width / image.size.height : 1;
    _aspect = fabs(a - 1) < 0.08 ? 1 : MAX(0.4, MIN(2.4, a));
    if (!image) { _heroBlur.image = nil; [self setNeedsLayout]; return; }

    // progressive blur source (60) and the colour mesh, both derived from the artwork itself
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *blurred = nil;
        @try {
            CIImage *ci = [CIImage imageWithCGImage:image.CGImage];
            if (ci) {
                CGFloat scale = 360.0 / MAX(1, ci.extent.size.width);   // blur a small copy: cheap and smoother
                CIImage *small = [ci imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
                CIImage *out = [[small imageByClampingToExtent] imageByApplyingGaussianBlurWithSigma:22];
                CGImageRef cg = [[CIContext context] createCGImage:out fromRect:small.extent];
                if (cg) { blurred = [UIImage imageWithCGImage:cg]; CGImageRelease(cg); }
            }
        } @catch (__unused NSException *e) {}
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![key isEqualToString:self->_imageKey]) return;
            [UIView transitionWithView:self->_heroBlur duration:0.35 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
                self->_heroBlur.image = blurred;
            } completion:nil];
        });
    });
    [IVLTheme dominantColorsOfImage:image completion:^(UIColor *top, UIColor *bottom) {
        if (![key isEqualToString:self->_imageKey]) return;
        CGFloat h, s, b, al;
        [top getHue:&h saturation:&s brightness:&b alpha:&al];
        UIColor *mid = [UIColor colorWithHue:h saturation:s brightness:b * 0.8 alpha:1];
        [CATransaction begin];
        [CATransaction setAnimationDuration:0.6];
        self->_mesh.colors = @[(id)top.CGColor, (id)mid.CGColor, (id)bottom.CGColor];
        [CATransaction commit];
    }];
    [self setNeedsLayout];
}

#pragma mark Layout

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    UIEdgeInsets safe = self.safeAreaInsets;
    CGFloat inner = W - kPad * 2;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _mesh.frame = self.bounds;

    // ---- control deck, from the bottom up
    CGFloat y = H - MAX(safe.bottom, 12) - 6;
    CGFloat footerH = 44;
    y -= footerH;
    CGFloat third = inner / 3;
    _lyricsBtn.frame = CGRectMake(kPad + (third - 44) / 2, y, 44, 44);
    _airplay.frame = CGRectMake(kPad + third + (third - 44) / 2, y, 44, 44);
    _queueBtn.frame = CGRectMake(kPad + third * 2 + (third - 44) / 2, y, 44, 44);
    _badge.frame = CGRectMake(CGRectGetMaxX(_queueBtn.frame) - 12, y + 9, 6, 6);
    y -= 22;
    // volume: speaker icons at both ends of a knobless capsule
    CGFloat volH = 24;
    y -= volH;
    _volLow.frame = CGRectMake(kPad, y, 18, volH);
    _volHigh.frame = CGRectMake(W - kPad - 22, y, 22, volH);
    _volume.frame = CGRectMake(kPad + 26, y, inner - 26 - 30, volH);
    y -= 32;                                                    // 28–36 margin
    CGFloat transport = 60;
    y -= transport;
    CGFloat cx = W / 2;
    _play.frame = CGRectMake(cx - 32, y, 64, transport);
    _prev.frame = CGRectMake(cx - 32 - 44 - 56, y, 56, transport);
    _next.frame = CGRectMake(cx + 32 + 44, y, 56, transport);
    y -= 30;                                                    // 28–36 margin
    _elapsed.frame = CGRectMake(kPad, y - 15, inner / 2, 15);
    _remaining.frame = CGRectMake(kPad + inner / 2, y - 15, inner / 2, 15);
    y -= 15 + 5;
    _seek.frame = CGRectMake(kPad, y - 22, inner, 22);          // 6pt capsule in a 22pt touch shell
    y -= 22 + 10;
    _lyric.frame = CGRectMake(kPad, y - 20, inner, 20);
    y -= 20 + 12;
    CGFloat actions = 34 * 2 + 4;
    _artist.frame = CGRectMake(kPad, y - 23, inner - actions - 8, 23);
    y -= 23 + 3;                                                // 2–4pt between title and artist
    _title.frame = CGRectMake(kPad, y - 27, inner - actions - 8, 27);
    _more.frame = CGRectMake(W - kPad - 34 + 6, y - 27 + 8, 34, 34);
    _star.frame = CGRectMake(CGRectGetMinX(_more.frame) - 36, y - 27 + 8, 34, 34);
    y -= 27;
    CGFloat deckTop = y;

    // ---- hero canvas & optical dissolve, measured from where the deck begins
    CGFloat dissolveStart = deckTop - H * 0.10, dissolveEnd = deckTop + H * 0.07;
    CGRect hero;
    if (_aspect > 1.05) {
        // wide video: its own shape across the full width, just under the status bar
        CGFloat h = W / _aspect;
        hero = CGRectMake(0, MAX(safe.top + 24, (dissolveStart - h) / 2 + safe.top / 2), W, h);
    } else {
        // song cover (1:1) or tall: full-bleed from the very top down into the dissolve zone
        hero = CGRectMake(0, 0, W, MAX(dissolveEnd, W / MAX(0.4, _aspect)));
    }
    _hero.frame = hero;
    _heroMask.frame = _hero.bounds;
    CGFloat hh = MAX(1, hero.size.height);
    if (_aspect > 1.05) {
        // a video dissolves on both edges so the frame floats in its own colour, no hard line
        _heroMask.colors = @[(id)UIColor.clearColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor];
        _heroMask.locations = @[@0, @0.06, @0.82, @1];
    } else {
        _heroMask.colors = @[(id)UIColor.blackColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor];
        _heroMask.locations = @[@0, @(MIN(0.99, MAX(0, (dissolveStart - hero.origin.y) / hh))), @(MIN(1, MAX(0.01, (dissolveEnd - hero.origin.y) / hh)))];
    }
    // the blurred copy covers the page and fades IN through the dissolve zone, then keeps
    // bleeding the artwork's light behind the deck
    _heroBlur.frame = self.bounds;
    _blurMask.frame = _heroBlur.bounds;
    CGFloat bs = MAX(0, (_aspect > 1.05 ? CGRectGetMaxY(hero) - hero.size.height * 0.35 : dissolveStart) / H);
    _blurMask.colors = @[(id)UIColor.clearColor.CGColor, (id)UIColor.blackColor.CGColor, (id)[UIColor colorWithWhite:0 alpha:0.55].CGColor];
    _blurMask.locations = @[@(MIN(0.98, bs)), @(MIN(0.99, MAX(bs + 0.01, dissolveEnd / H))), @1];
    [CATransaction commit];

    _grabber.frame = CGRectMake((W - 36) / 2, safe.top + 6, 36, 4);
}

#pragma mark Refresh

- (void)refresh {
    IVLPlaybackManager *m = [IVLPlaybackManager shared];
    IVLTrack *t = m.track;
    NSString *title = t.title ?: @"";
    if (![title isEqualToString:_title.attributedText.string ?: @""]) {
        _title.attributedText = [[NSAttributedString alloc] initWithString:title attributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:21 weight:UIFontWeightBold],
            NSForegroundColorAttributeName: IVLPrimary,
            NSKernAttributeName: @(-0.42),   // -0.02em
        }];
    }
    _artist.text = t.artist;

    double dur = MAX(0, t.duration);
    double pos = [m rawTimeMs] / 1000.0;
    if (!_seek.dragging && dur > 0) {
        _seek.value = MIN(1, pos / dur);
        _elapsed.text = IVLClock(pos);
        _remaining.text = [@"-" stringByAppendingString:IVLClock(dur - pos)];
    }
    NSString *line = [m currentLineText];
    NSString *shown = [line isEqualToString:@"♪"] ? @"• • •" : (line ?: @"");
    if (![shown isEqualToString:_lyric.text ?: @""]) {
        [UIView transitionWithView:_lyric duration:0.25 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{ self->_lyric.text = shown; } completion:nil];
    }

    BOOL playing = [IVLRemoteControl isPlaying];
    if (playing != _shownPlaying) {
        _shownPlaying = playing;
        [_play setSymbol:playing ? @"pause.fill" : @"play.fill" size:44];
    }
    _star.hidden = ![IVLRemoteControl canLike];
    _badge.hidden = ![IVLSleepTimer shared].active;   // state micro badge
}

#pragma mark Volume

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    dispatch_async(dispatch_get_main_queue(), ^{ [self syncVolume]; });
}

- (void)syncVolume {
    if (!_volume.dragging) _volume.value = [AVAudioSession sharedInstance].outputVolume;
}

- (void)volumeMoved {
    if (!_systemSlider) for (UIView *v in _systemVolume.subviews) if ([v isKindOfClass:[UISlider class]]) _systemSlider = (UISlider *)v;
    _systemSlider.value = _volume.value;
    [_systemSlider sendActionsForControlEvents:UIControlEventValueChanged];
}

#pragma mark Actions

- (void)seekMoved {
    double dur = [IVLPlaybackManager shared].track.duration;
    _elapsed.text = IVLClock(_seek.value * dur);
    _remaining.text = [@"-" stringByAppendingString:IVLClock(dur - _seek.value * dur)];
}

- (void)seekEnded {
    IVLPlaybackManager *m = [IVLPlaybackManager shared];
    double dur = m.track.duration;
    if (dur > 0) [m seekToMs:(NSInteger)(_seek.value * dur * 1000) + [IVLSettings integerForKey:IVLKeyGlobalOffset] + [m songOffsetMs]];
}

- (void)prevTapped { [[UIImpactFeedbackGenerator new] impactOccurred]; [IVLRemoteControl previous]; }
- (void)nextTapped { [[UIImpactFeedbackGenerator new] impactOccurred]; [IVLRemoteControl next]; }
- (void)playTapped { [[UIImpactFeedbackGenerator new] impactOccurred]; [IVLRemoteControl togglePlayPause]; }
- (void)starTapped {
    if ([IVLRemoteControl like]) {
        [_star setSymbol:@"star.fill" size:17];
        [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
    }
}
- (void)lyricsTapped { if (self.onShowLyrics) self.onShowLyrics(); }
- (void)queueTapped { if (self.onQueue) self.onQueue(); }

- (void)pan:(UIPanGestureRecognizer *)g {
    CGFloat ty = MAX(0, [g translationInView:self].y);
    if (g.state == UIGestureRecognizerStateChanged) {
        self.transform = CGAffineTransformMakeTranslation(0, ty);
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        if ((ty > 140 || [g velocityInView:self].y > 900) && self.onClose) {
            [UIView animateWithDuration:0.22 animations:^{ self.transform = CGAffineTransformMakeTranslation(0, self.bounds.size.height); }
                             completion:^(BOOL f) { self.transform = CGAffineTransformIdentity; self.onClose(); }];
        } else {
            [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0 options:0 animations:^{ self.transform = CGAffineTransformIdentity; } completion:nil];
        }
    }
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (g != _pan) return [super gestureRecognizerShouldBegin:g];
    // only vertical drags that start above the deck (the hero) close the sheet
    CGPoint v = [_pan velocityInView:self];
    CGPoint p = [_pan locationInView:self];
    return v.y > fabs(v.x) && p.y < CGRectGetMinY(_title.frame);
}

@end
