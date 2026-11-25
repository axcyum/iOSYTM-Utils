// Apple Music-style player page, laid out after SimpMusic's NowPlayingContentAppleMusic /
// AppleMusicShared / AppleMusicLyricStrip:
//  * the controls hang from the bottom: lyric strip on top of the progress bar, times, transport
//  * the bar is track-only (no thumb), 8.4pt thick, 16.8pt while touched, 20pt side insets
//  * transport: previous 56 / play 76 / next 56, 58pt apart, centred
//  * the artwork takes ITS OWN shape in the space above: a song (about 1:1) is a rounded square,
//    a wide video (16:9 etc.) runs edge to edge, a tall video is a rounded card, 16pt gaps.

#import "IVLPlayerPanel.h"
#import "IVLPlaybackManager.h"
#import "IVLRemoteControl.h"
#import "IVLExtras.h"
#import "IVLSettings.h"

static const CGFloat kSide = 20;          // SimpMusic: padding(horizontal = 20.dp)
static const CGFloat kGap = 16;           // VIDEO_FRAME_TOP_GAP / BOTTOM_GAP
static const CGFloat kTrack = 8.4;
static const CGFloat kTrackPressed = 16.8;

static NSString *IVLClock(double s) {
    long v = (long)MAX(0, floor(s));
    return [NSString stringWithFormat:@"%ld:%02ld", v / 60, v % 60];
}

#pragma mark - Track-only progress bar

@interface IVLSeekBar : UIControl
@property (nonatomic) CGFloat value;          // 0...1
@property (nonatomic, readonly) BOOL tracking;
@property (nonatomic, strong) UIColor *activeColor;
@end

@implementation IVLSeekBar {
    UIView *_track, *_fill;
    CGFloat _height;
    BOOL _tracking;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _height = kTrack;
        _track = [UIView new];
        _track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.22];
        _track.clipsToBounds = YES;
        _track.userInteractionEnabled = NO;
        _fill = [UIView new];
        _fill.backgroundColor = UIColor.whiteColor;
        [_track addSubview:_fill];
        [self addSubview:_track];
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitAdjustable;
    }
    return self;
}

- (BOOL)tracking { return _tracking; }
- (void)setActiveColor:(UIColor *)c { _activeColor = c; _fill.backgroundColor = c ?: UIColor.whiteColor; }
- (void)setValue:(CGFloat)value { _value = MIN(1, MAX(0, value)); [self setNeedsLayout]; }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    _track.frame = CGRectMake(0, (self.bounds.size.height - _height) / 2, w, _height);
    _track.layer.cornerRadius = _height / 2;
    _fill.frame = CGRectMake(0, 0, w * _value, _height);
}

- (void)setPressed:(BOOL)pressed {
    _height = pressed ? kTrackPressed : kTrack;
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        [self layoutSubviews];
    } completion:nil];
}

- (void)updateFromTouch:(UITouch *)t {
    self.value = [t locationInView:self].x / MAX(1, self.bounds.size.width);
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

- (BOOL)beginTrackingWithTouch:(UITouch *)t withEvent:(UIEvent *)e {
    _tracking = YES;
    [self setPressed:YES];
    [self updateFromTouch:t];
    return YES;
}
- (BOOL)continueTrackingWithTouch:(UITouch *)t withEvent:(UIEvent *)e { [self updateFromTouch:t]; return YES; }
- (void)endTrackingWithTouch:(UITouch *)t withEvent:(UIEvent *)e {
    _tracking = NO;
    [self setPressed:NO];
    [self sendActionsForControlEvents:UIControlEventTouchUpInside];
}
- (void)cancelTrackingWithEvent:(UIEvent *)e {
    _tracking = NO;
    [self setPressed:NO];
    [self sendActionsForControlEvents:UIControlEventTouchUpInside];
}
- (void)accessibilityIncrement { self.value += 0.05; [self sendActionsForControlEvents:UIControlEventTouchUpInside]; }
- (void)accessibilityDecrement { self.value -= 0.05; [self sendActionsForControlEvents:UIControlEventTouchUpInside]; }

@end

#pragma mark - Panel

@implementation IVLPlayerPanel {
    UIView *_artHost;
    UIImageView *_art;
    UILabel *_lyric, *_elapsed, *_remaining;
    IVLSeekBar *_bar;
    UIButton *_prev, *_playPause, *_next;
    BOOL _shownPlaying;
    CGFloat _aspect;            // width / height of the artwork image
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _aspect = 1;
        _artHost = [UIView new];
        _artHost.layer.shadowColor = UIColor.blackColor.CGColor;
        _artHost.layer.shadowOpacity = 0.4;
        _artHost.layer.shadowRadius = 20;
        _artHost.layer.shadowOffset = CGSizeMake(0, 10);
        _art = [UIImageView new];
        _art.contentMode = UIViewContentModeScaleAspectFill;
        _art.clipsToBounds = YES;
        _art.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        [_artHost addSubview:_art];

        _lyric = [UILabel new];
        _lyric.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        _lyric.textColor = UIColor.whiteColor;
        _lyric.lineBreakMode = NSLineBreakByTruncatingTail;
        _lyric.userInteractionEnabled = YES;
        [_lyric addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(lyricsTapped)]];

        _bar = [IVLSeekBar new];
        [_bar addTarget:self action:@selector(scrubMoved) forControlEvents:UIControlEventValueChanged];
        [_bar addTarget:self action:@selector(scrubEnded) forControlEvents:UIControlEventTouchUpInside];

        _elapsed = [UILabel new];
        _remaining = [UILabel new];
        for (UILabel *l in @[_elapsed, _remaining]) {
            l.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
            l.textColor = [UIColor colorWithWhite:1 alpha:0.6];
        }
        _remaining.textAlignment = NSTextAlignmentRight;

        _prev = [self control:@"backward.fill" point:34 action:@selector(prevTapped)];
        _playPause = [self control:@"pause.fill" point:48 action:@selector(playTapped)];
        _next = [self control:@"forward.fill" point:34 action:@selector(nextTapped)];

        for (UIView *v in @[_artHost, _lyric, _bar, _elapsed, _remaining, _prev, _playPause, _next]) [self addSubview:v];
        _shownPlaying = YES;
    }
    return self;
}

- (UIButton *)control:(NSString *)symbol point:(CGFloat)pt action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setImage:[UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:pt weight:UIImageSymbolWeightBold]] forState:UIControlStateNormal];
    b.tintColor = UIColor.whiteColor;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)setArtwork:(UIImage *)image {
    _art.image = image;
    CGFloat a = (image && image.size.height > 0) ? image.size.width / image.size.height : 1;
    // thumbnails are rarely exactly square: anything close is treated as a song cover
    if (fabs(a - 1) < 0.08) a = 1;
    _aspect = MAX(0.4, MIN(2.4, a));
    [self setNeedsLayout];
}

/// Manual layout so the bar and the transport sit exactly on the centre line.
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    CGFloat inner = W - kSide * 2;

    // ---- bottom cluster, from the bottom up
    CGFloat y = H - 8;
    CGFloat transport = 76;
    y -= transport;
    CGFloat cx = W / 2;
    _playPause.frame = CGRectMake(cx - 38, y, 76, 76);
    _prev.frame = CGRectMake(cx - 38 - 58 - 56, y + 10, 56, 56);
    _next.frame = CGRectMake(cx + 38 + 58, y + 10, 56, 56);
    y -= 14;
    _elapsed.frame = CGRectMake(kSide, y - 16, inner / 2, 16);
    _remaining.frame = CGRectMake(kSide + inner / 2, y - 16, inner / 2, 16);
    y -= 16 + 6;
    _bar.frame = CGRectMake(kSide, y - 18, inner, 18);   // 18pt shell, like SimpMusic
    y -= 18 + 2;                                          // "the lyric sits right on the progress bar"
    _lyric.frame = CGRectMake(kSide, y - 24, inner, 24);
    y -= 24;

    // ---- artwork in the space above, at its own shape
    CGFloat top = kGap, bottom = y - kGap;
    CGFloat availH = MAX(40, bottom - top);
    CGRect art;
    if (_aspect > 1.05) {
        // wide video: full width, square corners, centred in the region
        CGFloat w = MIN(W, availH * _aspect);
        CGFloat h = w / _aspect;
        art = CGRectMake((W - w) / 2, top + (availH - h) / 2, w, h);
        _art.layer.cornerRadius = w >= W - 1 ? 0 : 12;
    } else {
        // song cover (1:1) or tall video: a rounded card inside the side insets
        CGFloat h = MIN(availH, inner / _aspect);
        CGFloat w = h * _aspect;
        art = CGRectMake((W - w) / 2, top + (availH - h) / 2, w, h);
        _art.layer.cornerRadius = 12;
    }
    BOOL paused = !_shownPlaying;
    _artHost.transform = CGAffineTransformIdentity;
    _artHost.frame = art;
    _art.frame = _artHost.bounds;
    _artHost.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_artHost.bounds cornerRadius:_art.layer.cornerRadius].CGPath;
    if (paused && _aspect <= 1.05) _artHost.transform = CGAffineTransformMakeScale(0.82, 0.82);
}

- (void)refresh {
    IVLPlaybackManager *m = [IVLPlaybackManager shared];
    IVLTrack *t = m.track;
    double dur = MAX(0, t.duration);
    double pos = [m rawTimeMs] / 1000.0;
    if (!_bar.tracking && dur > 0) {
        _bar.value = MIN(1, pos / dur);
        _elapsed.text = IVLClock(pos);
        _remaining.text = [@"-" stringByAppendingString:IVLClock(dur - pos)];
    }
    _bar.activeColor = [IVLTheme accentColor];
    NSString *line = [m currentLineText];
    NSString *shown = [line isEqualToString:@"♪"] ? @"• • •" : (line ?: @"");
    if (![shown isEqualToString:_lyric.text ?: @""]) {
        [UIView transitionWithView:_lyric duration:0.25 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{ self->_lyric.text = shown; } completion:nil];
    }

    BOOL playing = [IVLRemoteControl isPlaying];
    if (playing != _shownPlaying) {
        _shownPlaying = playing;
        [_playPause setImage:[UIImage systemImageNamed:playing ? @"pause.fill" : @"play.fill"
                                     withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:48 weight:UIImageSymbolWeightBold]] forState:UIControlStateNormal];
        // Apple Music: a cover shrinks while paused (videos keep their frame)
        if (_aspect <= 1.05) {
            [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0 options:UIViewAnimationOptionAllowUserInteraction animations:^{
                self->_artHost.transform = playing ? CGAffineTransformIdentity : CGAffineTransformMakeScale(0.82, 0.82);
                self->_artHost.layer.shadowOpacity = playing ? 0.4 : 0.15;
            } completion:nil];
        }
    }
}

- (void)scrubMoved {
    double dur = [IVLPlaybackManager shared].track.duration;
    _elapsed.text = IVLClock(_bar.value * dur);
    _remaining.text = [@"-" stringByAppendingString:IVLClock(dur - _bar.value * dur)];
}

- (void)scrubEnded {
    IVLPlaybackManager *m = [IVLPlaybackManager shared];
    double dur = m.track.duration;
    if (dur > 0) {
        NSInteger rawMs = (NSInteger)(_bar.value * dur * 1000);
        // seekToMs: takes lyric time; add the offsets back so the player lands on rawMs
        [m seekToMs:rawMs + [IVLSettings integerForKey:IVLKeyGlobalOffset] + [m songOffsetMs]];
    }
}

- (void)prevTapped { [[UIImpactFeedbackGenerator new] impactOccurred]; [IVLRemoteControl previous]; }
- (void)nextTapped { [[UIImpactFeedbackGenerator new] impactOccurred]; [IVLRemoteControl next]; }
- (void)playTapped { [[UIImpactFeedbackGenerator new] impactOccurred]; [IVLRemoteControl togglePlayPause]; }
- (void)lyricsTapped { if (self.onShowLyrics) self.onShowLyrics(); }

@end
