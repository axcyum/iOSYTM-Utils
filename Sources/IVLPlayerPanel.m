#import "IVLPlayerPanel.h"
#import "IVLPlaybackManager.h"
#import "IVLRemoteControl.h"
#import "IVLExtras.h"
#import "IVLSettings.h"

static NSString *IVLClock(double s) {
    long v = (long)MAX(0, floor(s));
    return [NSString stringWithFormat:@"%ld:%02ld", v / 60, v % 60];
}

@implementation IVLPlayerPanel {
    UIView *_artHost;
    UIImageView *_art;
    UILabel *_title, *_artist, *_elapsed, *_remaining, *_lyric;
    UISlider *_slider;
    UIButton *_prev, *_playPause, *_next;
    BOOL _scrubbing;
    BOOL _shownPlaying;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _artHost = [UIView new];
        _artHost.layer.shadowColor = UIColor.blackColor.CGColor;
        _artHost.layer.shadowOpacity = 0.45;
        _artHost.layer.shadowRadius = 24;
        _artHost.layer.shadowOffset = CGSizeMake(0, 12);
        _art = [UIImageView new];
        _art.contentMode = UIViewContentModeScaleAspectFill;
        _art.clipsToBounds = YES;
        _art.layer.cornerRadius = 14;
        _art.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        _art.translatesAutoresizingMaskIntoConstraints = NO;
        [_artHost addSubview:_art];

        _title = [UILabel new];
        _title.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
        _title.textColor = UIColor.whiteColor;
        _artist = [UILabel new];
        _artist.font = [UIFont systemFontOfSize:19 weight:UIFontWeightRegular];
        _artist.textColor = [UIColor colorWithWhite:1 alpha:0.65];

        _slider = [UISlider new];
        _slider.minimumTrackTintColor = UIColor.whiteColor;
        _slider.maximumTrackTintColor = [UIColor colorWithWhite:1 alpha:0.25];
        [_slider setThumbImage:[self thumbOfSize:8] forState:UIControlStateNormal];
        [_slider setThumbImage:[self thumbOfSize:22] forState:UIControlStateHighlighted];
        [_slider addTarget:self action:@selector(scrubBegan) forControlEvents:UIControlEventTouchDown];
        [_slider addTarget:self action:@selector(scrubMoved) forControlEvents:UIControlEventValueChanged];
        [_slider addTarget:self action:@selector(scrubEnded) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];

        _elapsed = [UILabel new];
        _remaining = [UILabel new];
        for (UILabel *l in @[_elapsed, _remaining]) {
            l.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
            l.textColor = [UIColor colorWithWhite:1 alpha:0.55];
        }
        _remaining.textAlignment = NSTextAlignmentRight;

        _prev = [self control:@"backward.fill" size:30 action:@selector(prevTapped)];
        _playPause = [self control:@"play.fill" size:44 action:@selector(playTapped)];
        _next = [self control:@"forward.fill" size:30 action:@selector(nextTapped)];

        _lyric = [UILabel new];
        _lyric.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        _lyric.textColor = [UIColor colorWithWhite:1 alpha:0.85];
        _lyric.textAlignment = NSTextAlignmentCenter;
        _lyric.numberOfLines = 2;
        _lyric.userInteractionEnabled = YES;
        [_lyric addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(lyricsTapped)]];

        UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[_title, _artist]];
        texts.axis = UILayoutConstraintAxisVertical;
        texts.spacing = 2;
        UIStackView *times = [[UIStackView alloc] initWithArrangedSubviews:@[_elapsed, _remaining]];
        times.distribution = UIStackViewDistributionFillEqually;
        UIStackView *controls = [[UIStackView alloc] initWithArrangedSubviews:@[_prev, _playPause, _next]];
        controls.distribution = UIStackViewDistributionEqualSpacing;
        controls.alignment = UIStackViewAlignmentCenter;

        UIStackView *bottom = [[UIStackView alloc] initWithArrangedSubviews:@[texts, _slider, times, controls, _lyric]];
        bottom.axis = UILayoutConstraintAxisVertical;
        bottom.spacing = 10;
        [bottom setCustomSpacing:18 afterView:texts];
        [bottom setCustomSpacing:22 afterView:times];
        [bottom setCustomSpacing:22 afterView:controls];

        for (UIView *v in @[_artHost, bottom]) { v.translatesAutoresizingMaskIntoConstraints = NO; [self addSubview:v]; }
        NSLayoutConstraint *square = [_artHost.heightAnchor constraintEqualToAnchor:_artHost.widthAnchor];
        NSLayoutConstraint *wide = [_artHost.widthAnchor constraintEqualToAnchor:self.widthAnchor constant:-56];
        wide.priority = UILayoutPriorityDefaultHigh;
        [NSLayoutConstraint activateConstraints:@[
            [_artHost.topAnchor constraintEqualToAnchor:self.topAnchor constant:12],
            [_artHost.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            square, wide,
            [_artHost.bottomAnchor constraintLessThanOrEqualToAnchor:bottom.topAnchor constant:-24],
            [_art.topAnchor constraintEqualToAnchor:_artHost.topAnchor],
            [_art.bottomAnchor constraintEqualToAnchor:_artHost.bottomAnchor],
            [_art.leadingAnchor constraintEqualToAnchor:_artHost.leadingAnchor],
            [_art.trailingAnchor constraintEqualToAnchor:_artHost.trailingAnchor],
            [bottom.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:28],
            [bottom.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-28],
            [bottom.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-12],
            [controls.leadingAnchor constraintEqualToAnchor:bottom.leadingAnchor constant:30],
            [controls.trailingAnchor constraintEqualToAnchor:bottom.trailingAnchor constant:-30],
        ]];
        _shownPlaying = YES;
    }
    return self;
}

- (UIImage *)thumbOfSize:(CGFloat)d {
    return [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(d, d)] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [UIColor.whiteColor setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, d, d)] fill];
    }];
}

- (UIButton *)control:(NSString *)symbol size:(CGFloat)size action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setImage:[UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightBold]] forState:UIControlStateNormal];
    b.tintColor = UIColor.whiteColor;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [b.widthAnchor constraintEqualToConstant:64].active = YES;
    [b.heightAnchor constraintEqualToConstant:64].active = YES;
    return b;
}

- (void)setArtwork:(UIImage *)image { _art.image = image; }

- (void)refresh {
    IVLPlaybackManager *m = [IVLPlaybackManager shared];
    IVLTrack *t = m.track;
    _title.text = t.title;
    _artist.text = t.artist;
    double dur = MAX(0, t.duration);
    double pos = [m rawTimeMs] / 1000.0;
    if (!_scrubbing && dur > 0) {
        _slider.value = (float)MIN(1, pos / dur);
        _elapsed.text = IVLClock(pos);
        _remaining.text = [@"-" stringByAppendingString:IVLClock(dur - pos)];
    }
    _slider.minimumTrackTintColor = [IVLTheme accentColor];
    NSString *line = [m currentLineText];
    _lyric.text = [line isEqualToString:@"♪"] ? @"• • •" : line;

    BOOL playing = [IVLRemoteControl isPlaying];
    if (playing != _shownPlaying) {
        _shownPlaying = playing;
        [_playPause setImage:[UIImage systemImageNamed:playing ? @"pause.fill" : @"play.fill"
                                     withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:44 weight:UIImageSymbolWeightBold]] forState:UIControlStateNormal];
        // Apple Music: the artwork shrinks while paused
        [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0 options:UIViewAnimationOptionAllowUserInteraction animations:^{
            self->_artHost.transform = playing ? CGAffineTransformIdentity : CGAffineTransformMakeScale(0.82, 0.82);
            self->_artHost.layer.shadowOpacity = playing ? 0.45 : 0.15;
        } completion:nil];
    }
}

- (void)scrubBegan { _scrubbing = YES; }

- (void)scrubMoved {
    double dur = [IVLPlaybackManager shared].track.duration;
    _elapsed.text = IVLClock(_slider.value * dur);
    _remaining.text = [@"-" stringByAppendingString:IVLClock(dur - _slider.value * dur)];
}

- (void)scrubEnded {
    IVLPlaybackManager *m = [IVLPlaybackManager shared];
    double dur = m.track.duration;
    if (dur > 0) {
        NSInteger rawMs = (NSInteger)(_slider.value * dur * 1000);
        // seekToMs: takes lyric time; add the offsets back so the player lands on rawMs
        [m seekToMs:rawMs + [IVLSettings integerForKey:IVLKeyGlobalOffset] + [m songOffsetMs]];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ self->_scrubbing = NO; });
}

- (void)prevTapped { [[UIImpactFeedbackGenerator new] impactOccurred]; [IVLRemoteControl previous]; }
- (void)nextTapped { [[UIImpactFeedbackGenerator new] impactOccurred]; [IVLRemoteControl next]; }
- (void)playTapped { [[UIImpactFeedbackGenerator new] impactOccurred]; [IVLRemoteControl togglePlayPause]; }
- (void)lyricsTapped { if (self.onShowLyrics) self.onShowLyrics(); }

@end
