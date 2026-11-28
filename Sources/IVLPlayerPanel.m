// Internal "Now Playing" sheet keeping the clean atmospheric design language:
//  - Default mode: standard framed 1:1 rounded square cover (songs) or 16:9 rounded thumbnail
//    (videos) floating over a soft blurred-artwork colour mesh background; tapping the cover returns
//    to the lyrics screen.
//  - Experimental mode (IVLKeyImmersivePlayer): Apple Music (v27) full-bleed artwork behind the
//    status bar dissolving optically into the colour mesh, PLUS a dedicated Apple Music inline
//    lyrics stage (compact header cover + title + star/more, graduated optical depth-of-field blur
//    on inactive lines, floating translation/pronunciation pill, active lyrics footer badge).
//  - Shared footer automatically switches the AirPlay icon to AirPods / Headphones (+ device name)
//    whenever an external audio route is active.

#import "IVLPlayerPanel.h"
#import "IVLPlaybackManager.h"
#import "IVLRemoteControl.h"
#import "IVLExtras.h"
#import "IVLSettings.h"
#import "IVLLocalization.h"
#import "IVLLyricCell.h"
#import "IVLLyricsViewController.h"
#import "IVLAudioDSP.h"
#import "IVLExternalDisplay.h"
#import "IVLTranslator.h"
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
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
- (void)setSymbol:(NSString *)symbol size:(CGFloat)pt;
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
    if (img) [self setImage:img forState:UIControlStateNormal];
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

#pragma mark - Dedicated Apple Music Lyric Cell (Optical Depth-of-Field Blur)

@interface IVLAMLyricCell : UITableViewCell
+ (NSString *)reuseID;
- (void)configureWithLine:(IVLLyricLine *)line synced:(BOOL)synced karaoke:(BOOL)karaoke tier:(NSInteger)tier;
- (void)setTier:(NSInteger)tier animated:(BOOL)animated;   // 0 = active sharp, 1 = near blur, 2 = far blur
- (void)updateTime:(NSInteger)ms;
@end

@implementation IVLAMLyricCell {
    UIStackView *_stack;
    IVLKaraokeLabel *_label;
    UILabel *_pron;
    UILabel *_trans;
    UIStackView *_dots;
    UIImageView *_blurView;
    IVLLyricLine *_line;
    BOOL _synced;
    BOOL _karaoke;
    NSInteger _tier;
    NSString *_blurKey;
}

+ (NSString *)reuseID { return @"IVLAMLyricCell"; }

+ (NSCache<NSString *, UIImage *> *)blurCache {
    static NSCache<NSString *, UIImage *> *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [NSCache new]; c.countLimit = 180; });
    return c;
}

+ (CIContext *)ciContext {
    static CIContext *ctx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ctx = [CIContext contextWithOptions:@{ kCIContextWorkingColorSpace: [NSNull null] }]; });
    return ctx;
}

+ (dispatch_queue_t)blurQueue {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("ivl.am.blur", DISPATCH_QUEUE_SERIAL); });
    return q;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = UIColor.clearColor;
        self.contentView.backgroundColor = UIColor.clearColor;
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _label = [IVLKaraokeLabel new];
        _label.numberOfLines = 0;
        _label.textColor = IVLPrimary;
        _label.brightColor = [UIColor colorWithWhite:1 alpha:0.96];
        _label.dimColor = [UIColor colorWithWhite:1 alpha:0.38];

        _pron = [UILabel new];
        _pron.numberOfLines = 0;
        _pron.textColor = [UIColor colorWithWhite:1 alpha:0.62];

        _trans = [UILabel new];
        _trans.numberOfLines = 0;
        _trans.textColor = [UIColor colorWithWhite:1 alpha:0.78];

        _dots = [UIStackView new];
        _dots.axis = UILayoutConstraintAxisHorizontal;
        _dots.spacing = 8;
        for (int i = 0; i < 3; i++) {
            UIView *d = [UIView new];
            d.backgroundColor = UIColor.whiteColor;
            d.layer.cornerRadius = 4.5;
            d.alpha = 0.3;
            [d.widthAnchor constraintEqualToConstant:9].active = YES;
            [d.heightAnchor constraintEqualToConstant:9].active = YES;
            [_dots addArrangedSubview:d];
        }

        _stack = [[UIStackView alloc] initWithArrangedSubviews:@[_label, _pron, _trans, _dots]];
        _stack.axis = UILayoutConstraintAxisVertical;
        _stack.spacing = 4;
        _stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_stack];

        _blurView = [UIImageView new];
        _blurView.contentMode = UIViewContentModeScaleToFill;
        _blurView.userInteractionEnabled = NO;
        _blurView.hidden = YES;
        [self.contentView addSubview:_blurView];

        NSLayoutConstraint *bottom = [_stack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-11];
        bottom.priority = UILayoutPriorityDefaultHigh + 10;
        [NSLayoutConstraint activateConstraints:@[
            [_stack.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:kPad],
            [_stack.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-kPad],
            [_stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:11],
            bottom,
        ]];
        _tier = -1;
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [_dots.layer removeAllAnimations];
    _label.karaokeActive = NO;
    _label.words = nil;
    _blurView.hidden = YES;
    _blurView.image = nil;
    _blurKey = nil;
    _tier = -1;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self.contentView layoutIfNeeded];
    _blurView.frame = CGRectInset(_stack.frame, -10, -10);
    if (_tier > 0 && _synced && !_line.instrumental && !_blurView.image) {
        [self requestBlurredSnapshot];
    }
}

- (void)configureWithLine:(IVLLyricLine *)line synced:(BOOL)synced karaoke:(BOOL)karaoke tier:(NSInteger)tier {
    _line = line;
    _synced = synced;
    _karaoke = karaoke;
    _blurKey = nil;
    _blurView.image = nil;

    NSTextAlignment align = line.alternateVoice ? NSTextAlignmentRight : NSTextAlignmentLeft;
    UIStackViewAlignment stackAlign = align == NSTextAlignmentRight ? UIStackViewAlignmentTrailing : UIStackViewAlignmentLeading;

    if (line.instrumental) {
        _label.hidden = YES; _pron.hidden = YES; _trans.hidden = YES;
        _dots.hidden = NO;
        _stack.alignment = stackAlign;
    } else {
        _dots.hidden = YES;
        _label.hidden = NO;
        _stack.alignment = UIStackViewAlignmentFill;

        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
        ps.alignment = align;
        ps.lineBreakMode = NSLineBreakByWordWrapping;
        ps.lineSpacing = 3.0;
        UIFont *font = [UIFont systemFontOfSize:27.0 weight:UIFontWeightBold];
        _label.attributedText = [[NSAttributedString alloc] initWithString:line.text ?: @""
                                                                attributes:@{
            NSFontAttributeName: font,
            NSParagraphStyleAttributeName: ps,
            NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.96],
            NSKernAttributeName: @(-0.35),
        }];
        _label.words = (karaoke && synced) ? line.words : nil;

        _pron.hidden = line.pronunciation.length == 0;
        _pron.text = line.pronunciation;
        _pron.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightMedium];
        _pron.textAlignment = align;

        _trans.hidden = line.translation.length == 0;
        _trans.text = line.translation;
        _trans.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
        _trans.textAlignment = align;
    }
    _tier = -1;
    [self setTier:tier animated:NO];
}

- (CGFloat)alphaForTier:(NSInteger)tier {
    if (!_synced) return 0.90;
    if (_line.instrumental) return tier == 0 ? 1.0 : 0.24;
    if (tier == 0) return 1.0;
    return tier == 1 ? 0.42 : 0.26;
}

- (void)setTier:(NSInteger)tier animated:(BOOL)animated {
    if (_tier == tier) return;
    _tier = tier;
    BOOL active = (tier == 0);
    BOOL useKaraoke = active && _synced && _karaoke && _label.words.count > 0;
    _label.karaokeActive = useKaraoke;
    _label.layer.shadowColor = UIColor.whiteColor.CGColor;
    _label.layer.shadowRadius = 10;
    _label.layer.shadowOffset = CGSizeZero;
    _label.layer.shadowOpacity = (active && !useKaraoke && _synced) ? 0.22f : 0.0f;

    CGFloat targetAlpha = [self alphaForTier:tier];
    CGFloat scale = (active || !_synced) ? 1.0 : (tier == 1 ? 0.97 : 0.95);

    if (active || !_synced || _line.instrumental) {
        _blurKey = nil;
        void (^applySharp)(void) = ^{
            self->_blurView.alpha = 0;
            self->_stack.alpha = targetAlpha;
            self->_stack.transform = CGAffineTransformMakeScale(scale, scale);
        };
        if (animated) {
            [UIView animateWithDuration:0.32 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:applySharp completion:^(BOOL f) {
                if (self->_tier == 0) self->_blurView.hidden = YES;
            }];
        } else {
            applySharp();
            _blurView.hidden = YES;
        }
    } else {
        _blurView.transform = CGAffineTransformMakeScale(scale, scale);
        _stack.transform = CGAffineTransformMakeScale(scale, scale);
        [self requestBlurredSnapshot];
        if (!_blurView.image) {
            // Instant fallback while background blur renders on first pass
            _blurView.hidden = YES;
            _stack.alpha = targetAlpha;
        } else {
            void (^applyBlur)(void) = ^{
                self->_blurView.hidden = NO;
                self->_blurView.alpha = targetAlpha;
                self->_stack.alpha = 0;
            };
            if (animated) [UIView animateWithDuration:0.32 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:applyBlur completion:nil];
            else applyBlur();
        }
    }

    if (_line.instrumental) {
        [_dots.layer removeAllAnimations];
        if (active) {
            CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
            pulse.fromValue = @1.0; pulse.toValue = @1.16;
            pulse.duration = 0.95; pulse.autoreverses = YES; pulse.repeatCount = HUGE_VALF;
            pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            [_dots.layer addAnimation:pulse forKey:@"pulse"];
        } else {
            for (UIView *d in _dots.arrangedSubviews) d.alpha = 0.3;
        }
    }
}

- (void)requestBlurredSnapshot {
    if (_tier <= 0 || !_synced || _line.instrumental) return;
    CGSize sz = _stack.bounds.size;
    if (sz.width < 40 || sz.height < 10) return;

    NSInteger tier = _tier;
    NSString *text = _line.text ?: @"";
    NSString *pron = _pron.hidden ? @"" : (_line.pronunciation ?: @"");
    NSString *trans = _trans.hidden ? @"" : (_line.translation ?: @"");
    BOOL rightAlign = _line.alternateVoice;
    NSString *key = [NSString stringWithFormat:@"%ld|%.0f|%d|%@|%@|%@", (long)tier, sz.width, rightAlign, text, pron, trans];
    _blurKey = key;

    UIImage *cached = [[IVLAMLyricCell blurCache] objectForKey:key];
    if (cached) {
        _blurView.image = cached;
        _blurView.hidden = NO;
        _blurView.alpha = [self alphaForTier:tier];
        _stack.alpha = 0;
        return;
    }

    CGFloat pad = 10.0;
    CGSize canvas = CGSizeMake(sz.width + pad * 2, sz.height + pad * 2);
    CGFloat sigma = (tier == 1) ? 1.65 : 2.95;

    // Capture exact label frames on main thread, then render + blur off-main-thread
    CGRect rLabel = CGRectOffset(_label.frame, pad, pad);
    CGRect rPron  = _pron.hidden ? CGRectZero : CGRectOffset(_pron.frame, pad, pad);
    CGRect rTrans = _trans.hidden ? CGRectZero : CGRectOffset(_trans.frame, pad, pad);
    NSAttributedString *attrMain = [_label.attributedText copy];
    UIFont *fPron = _pron.font;
    UIFont *fTrans = _trans.font;
    NSTextAlignment align = rightAlign ? NSTextAlignmentRight : NSTextAlignmentLeft;

    __weak typeof(self) weakSelf = self;
    dispatch_async([IVLAMLyricCell blurQueue], ^{
        UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
        fmt.scale = 1.5;
        fmt.opaque = NO;
        UIImage *raw = [[[UIGraphicsImageRenderer alloc] initWithSize:canvas format:fmt] imageWithActions:^(UIGraphicsImageRendererContext *c) {
            [attrMain drawWithRect:rLabel options:NSStringDrawingUsesLineFragmentOrigin context:nil];
            if (pron.length) {
                NSMutableParagraphStyle *p = [NSMutableParagraphStyle new]; p.alignment = align;
                [pron drawWithRect:rPron options:NSStringDrawingUsesLineFragmentOrigin attributes:@{
                    NSFontAttributeName: fPron, NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.75], NSParagraphStyleAttributeName: p
                } context:nil];
            }
            if (trans.length) {
                NSMutableParagraphStyle *p = [NSMutableParagraphStyle new]; p.alignment = align;
                [trans drawWithRect:rTrans options:NSStringDrawingUsesLineFragmentOrigin attributes:@{
                    NSFontAttributeName: fTrans, NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.88], NSParagraphStyleAttributeName: p
                } context:nil];
            }
        }];
        UIImage *blurred = raw;
        @try {
            CIImage *ci = [CIImage imageWithCGImage:raw.CGImage];
            if (ci) {
                CIFilter *f = [CIFilter filterWithName:@"CIGaussianBlur" withInputParameters:@{
                    kCIInputImageKey: ci,
                    kCIInputRadiusKey: @(sigma * 1.5),
                }];
                CGImageRef cg = [[IVLAMLyricCell ciContext] createCGImage:f.outputImage fromRect:ci.extent];
                if (cg) {
                    blurred = [UIImage imageWithCGImage:cg scale:1.5 orientation:UIImageOrientationUp];
                    CGImageRelease(cg);
                }
            }
        } @catch (__unused NSException *e) {}
        if (blurred) [[IVLAMLyricCell blurCache] setObject:blurred forKey:key];

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || ![strongSelf->_blurKey isEqualToString:key] || strongSelf->_tier <= 0) return;
            strongSelf->_blurView.image = blurred;
            strongSelf->_blurView.hidden = NO;
            strongSelf->_blurView.alpha = [strongSelf alphaForTier:strongSelf->_tier];
            strongSelf->_stack.alpha = 0;
        });
    });
}

- (void)updateTime:(NSInteger)ms {
    if (_tier != 0) return;
    if (_line.instrumental) {
        CGFloat span = MAX(1, _line.endMs - _line.startMs);
        CGFloat p = MIN(1, MAX(0, (ms - _line.startMs) / span));
        NSArray *ds = _dots.arrangedSubviews;
        for (NSUInteger i = 0; i < ds.count; i++) {
            CGFloat local = MIN(1, MAX(0, p * ds.count - i));
            ((UIView *)ds[i]).alpha = 0.3 + 0.7 * local;
        }
        return;
    }
    _label.timeMs = ms;
}

@end

#pragma mark - Panel

@interface IVLPlayerPanel () <UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate>
@end

@implementation IVLPlayerPanel {
    // atmosphere & artwork
    CAGradientLayer *_mesh;
    UIImageView *_heroBlur;
    UIView *_lyricsDim;
    UIView *_artHost;
    UIImageView *_hero;
    CAGradientLayer *_heroMask, *_blurMask;
    UIView *_grabber;

    // compact header for Apple Music inline lyrics mode
    UIView *_compactHeader;
    UIImageView *_compactArt;
    UILabel *_compactTitle, *_compactArtist;

    // dedicated Apple Music lyrics stage
    UIView *_amStage;
    CAGradientLayer *_amFadeMask;
    UITableView *_amTable;
    UILabel *_amStateLabel;
    UIActivityIndicatorView *_amSpinner;
    UIButton *_amTransBtn;
    UIButton *_amSyncBtn;
    UIButton *_amAIBtn;
    UIImageView *_aiTopGlow;
    UIImageView *_aiBottomGlow;
    UIStackView *_amOffsetPanel;
    UILabel *_amOffsetLabel;
    BOOL _amOffsetVisible;
    NSArray<IVLLyricLine *> *_amLines;
    BOOL _amSynced;
    NSInteger _amActiveIndex;
    BOOL _amFollowing;
    NSTimer *_amResumeTimer;
    __weak IVLLyrics *_amShownLyrics;

    // deck
    UILabel *_title, *_artist, *_lyric, *_elapsed, *_remaining;
    IVLGlyphButton *_star, *_more, *_prev, *_play, *_next, *_lyricsBtn, *_queueBtn;
    UIView *_lyricsActivePill;
    UIView *_badge;

    // dynamic AirPlay / AirPods route slot
    AVRoutePickerView *_airplay;
    IVLGlyphButton *_routeBtn;
    UILabel *_routeLabel;

    IVLCapsuleBar *_seek, *_volume;
    UIImageView *_volLow, *_volHigh;
    MPVolumeView *_systemVolume;
    UISlider *_systemSlider;

    // state
    CGFloat _aspect;
    BOOL _shownPlaying;
    BOOL _lyricsMode;
    BOOL _needsAMInitialScroll;
    NSString *_imageKey;
    NSString *_shownVideoID;
    UIPanGestureRecognizer *_pan;
    UITapGestureRecognizer *_artTap;
}

- (BOOL)lyricsMode { return _lyricsMode; }

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _aspect = 1;
        _shownPlaying = YES;
        _amActiveIndex = -1;
        _amFollowing = YES;
        self.backgroundColor = UIColor.blackColor;
        self.clipsToBounds = YES;

        _mesh = [CAGradientLayer layer];
        _mesh.colors = @[(id)[UIColor colorWithWhite:0.18 alpha:1].CGColor, (id)[UIColor colorWithWhite:0.08 alpha:1].CGColor];
        [self.layer addSublayer:_mesh];

        _heroBlur = [UIImageView new];
        _heroBlur.contentMode = UIViewContentModeScaleAspectFill;
        _heroBlur.clipsToBounds = YES;
        _blurMask = [CAGradientLayer layer];
        [self addSubview:_heroBlur];

        _lyricsDim = [UIView new];
        _lyricsDim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.28];
        _lyricsDim.alpha = 0;
        _lyricsDim.userInteractionEnabled = NO;
        [self addSubview:_lyricsDim];

        _artHost = [UIView new];
        _artHost.layer.shadowColor = UIColor.blackColor.CGColor;
        _artHost.layer.shadowRadius = 22;
        _artHost.layer.shadowOffset = CGSizeMake(0, 12);
        _artHost.userInteractionEnabled = YES;
        [self addSubview:_artHost];

        _hero = [UIImageView new];
        _hero.contentMode = UIViewContentModeScaleAspectFill;
        _hero.clipsToBounds = YES;
        _hero.layer.cornerCurve = kCACornerCurveContinuous;
        _hero.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
        _heroMask = [CAGradientLayer layer];
        [_artHost addSubview:_hero];

        _artTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(artTapped)];
        _artTap.delegate = self;
        [_artHost addGestureRecognizer:_artTap];

        _grabber = [UIView new];
        _grabber.backgroundColor = [UIColor colorWithWhite:1 alpha:0.35];
        _grabber.layer.cornerRadius = 2;
        [self addSubview:_grabber];

        [self buildCompactHeader];
        [self buildAMLyricsStage];

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
            l.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
            l.textColor = IVLTertiary;
        }
        _remaining.textAlignment = NSTextAlignmentRight;

        _star = [IVLGlyphButton glyph:@"star" size:16 color:IVLSecondary];
        _star.layer.cornerCurve = kCACornerCurveContinuous;
        [_star addTarget:self action:@selector(starTapped) forControlEvents:UIControlEventTouchUpInside];
        _more = [IVLGlyphButton glyph:@"ellipsis" size:16 color:IVLSecondary];
        _more.layer.cornerCurve = kCACornerCurveContinuous;
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
        _systemVolume = [[MPVolumeView alloc] initWithFrame:CGRectMake(-2000, -2000, 10, 10)];
        _systemVolume.alpha = 0.01;
        for (UIView *v in _systemVolume.subviews) if ([v isKindOfClass:[UISlider class]]) _systemSlider = (UISlider *)v;
        [self addSubview:_systemVolume];

        _lyricsActivePill = [UIView new];
        _lyricsActivePill.backgroundColor = IVLPrimary;
        _lyricsActivePill.layer.cornerRadius = 9;
        _lyricsActivePill.layer.cornerCurve = kCACornerCurveContinuous;
        _lyricsActivePill.alpha = 0;
        _lyricsActivePill.userInteractionEnabled = NO;
        [self addSubview:_lyricsActivePill];

        _lyricsBtn = [IVLGlyphButton glyph:@"quote.bubble" size:20 color:IVLTertiary];
        [_lyricsBtn addTarget:self action:@selector(lyricsTapped) forControlEvents:UIControlEventTouchUpInside];

        _airplay = [AVRoutePickerView new];
        _airplay.prioritizesVideoDevices = NO;
        _airplay.alpha = 0.01;
        _airplay.userInteractionEnabled = NO;
        [self addSubview:_airplay];

        _routeBtn = [IVLGlyphButton glyph:@"airplayaudio" size:19 color:IVLTertiary];
        [_routeBtn addTarget:self action:@selector(routeTapped) forControlEvents:UIControlEventTouchUpInside];
        _routeLabel = [UILabel new];
        _routeLabel.font = [UIFont systemFontOfSize:9.5 weight:UIFontWeightSemibold];
        _routeLabel.textColor = IVLSecondary;
        _routeLabel.textAlignment = NSTextAlignmentCenter;
        _routeLabel.lineBreakMode = NSLineBreakByTruncatingTail;

        _queueBtn = [IVLGlyphButton glyph:@"list.bullet" size:20 color:IVLTertiary];
        [_queueBtn addTarget:self action:@selector(queueTapped) forControlEvents:UIControlEventTouchUpInside];
        _badge = [UIView new];
        _badge.backgroundColor = IVLPrimary;
        _badge.layer.cornerRadius = 3;
        _badge.hidden = YES;

        for (UIView *v in @[_title, _artist, _star, _more, _lyric, _seek, _elapsed, _remaining, _prev, _play, _next,
                            _volLow, _volume, _volHigh, _lyricsBtn, _routeBtn, _routeLabel, _queueBtn, _badge]) [self addSubview:v];

        _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
        _pan.delegate = self;
        [self addGestureRecognizer:_pan];

        [[AVAudioSession sharedInstance] addObserver:self forKeyPath:@"outputVolume" options:NSKeyValueObservingOptionNew context:NULL];
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(routeChanged:) name:AVAudioSessionRouteChangeNotification object:nil];
        [nc addObserver:self selector:@selector(settingsChanged:) name:IVLSettingsDidChangeNotification object:nil];
        [nc addObserver:self selector:@selector(reloadAMLyrics) name:IVLLyricsDidChangeNotification object:nil];
        [nc addObserver:self selector:@selector(trackDidChange) name:IVLTrackDidChangeNotification object:nil];
        [nc addObserver:self selector:@selector(artworkDidChange) name:IVLArtworkDidChangeNotification object:nil];

        [self syncVolume];
        [self updateAudioRoute];
        [self reloadAMLyrics];
        [self refreshAppleIntelligenceGlow];
    }
    return self;
}

- (void)dealloc {
    [_amResumeTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    @try { [[AVAudioSession sharedInstance] removeObserver:self forKeyPath:@"outputVolume"]; } @catch (__unused NSException *e) {}
}

- (void)buildCompactHeader {
    _compactHeader = [UIView new];
    _compactHeader.alpha = 0;
    _compactHeader.hidden = YES;
    [self addSubview:_compactHeader];

    _compactArt = [UIImageView new];
    _compactArt.contentMode = UIViewContentModeScaleAspectFill;
    _compactArt.clipsToBounds = YES;
    _compactArt.layer.cornerRadius = 8;
    _compactArt.layer.cornerCurve = kCACornerCurveContinuous;
    _compactArt.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    [_compactHeader addSubview:_compactArt];

    _compactTitle = [UILabel new];
    _compactTitle.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightBold];
    _compactTitle.textColor = IVLPrimary;
    [_compactHeader addSubview:_compactTitle];

    _compactArtist = [UILabel new];
    _compactArtist.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightRegular];
    _compactArtist.textColor = IVLSecondary;
    [_compactHeader addSubview:_compactArtist];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(compactHeaderTapped)];
    [_compactHeader addGestureRecognizer:tap];
}

- (void)buildAMLyricsStage {
    _amStage = [UIView new];
    _amStage.alpha = 0;
    _amStage.hidden = YES;
    [self addSubview:_amStage];

    _amTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _amTable.backgroundColor = UIColor.clearColor;
    _amTable.separatorStyle = UITableViewCellSeparatorStyleNone;
    _amTable.showsVerticalScrollIndicator = NO;
    _amTable.estimatedRowHeight = 62;
    _amTable.rowHeight = UITableViewAutomaticDimension;
    _amTable.dataSource = self;
    _amTable.delegate = self;
    _amTable.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [_amTable registerClass:[IVLAMLyricCell class] forCellReuseIdentifier:[IVLAMLyricCell reuseID]];
    [_amStage addSubview:_amTable];

    _amFadeMask = [CAGradientLayer layer];
    _amFadeMask.colors = @[(id)UIColor.clearColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor];
    _amFadeMask.locations = @[@0, @0.08, @0.88, @1];
    _amStage.layer.mask = _amFadeMask;

    _amSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _amSpinner.color = IVLSecondary;
    [_amStage addSubview:_amSpinner];

    _amStateLabel = [UILabel new];
    _amStateLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _amStateLabel.textColor = IVLSecondary;
    _amStateLabel.textAlignment = NSTextAlignmentCenter;
    _amStateLabel.numberOfLines = 0;
    [_amStage addSubview:_amStateLabel];

    _amTransBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _amTransBtn.layer.cornerRadius = 10;
    _amTransBtn.layer.cornerCurve = kCACornerCurveContinuous;
    _amTransBtn.showsMenuAsPrimaryAction = YES;
    _amTransBtn.alpha = 0;
    _amTransBtn.hidden = YES;
    [self addSubview:_amTransBtn];

    _amSyncBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _amSyncBtn.layer.cornerRadius = 10;
    _amSyncBtn.layer.cornerCurve = kCACornerCurveContinuous;
    _amSyncBtn.alpha = 0;
    _amSyncBtn.hidden = YES;
    [_amSyncBtn addTarget:self action:@selector(toggleAMOffsetPanel) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_amSyncBtn];

    if (IVLIsAppleIntelligenceAvailable()) {
        _amAIBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        _amAIBtn.layer.cornerRadius = 10;
        _amAIBtn.layer.cornerCurve = kCACornerCurveContinuous;
        _amAIBtn.clipsToBounds = YES;
        _amAIBtn.imageView.contentMode = UIViewContentModeScaleAspectFill;
        [_amAIBtn setImage:IVLAppleIntelligenceIconImage() forState:UIControlStateNormal];
        _amAIBtn.alpha = 0;
        _amAIBtn.hidden = YES;
        [_amAIBtn addTarget:self action:@selector(amAITranslateTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_amAIBtn];

        _aiTopGlow = [[UIImageView alloc] initWithImage:IVLAppleIntelligenceTopGlowImage()];
        _aiTopGlow.contentMode = UIViewContentModeScaleToFill;
        _aiTopGlow.userInteractionEnabled = NO;
        _aiTopGlow.alpha = 0;
        [self addSubview:_aiTopGlow];

        _aiBottomGlow = [[UIImageView alloc] initWithImage:IVLAppleIntelligenceBottomGlowImage()];
        _aiBottomGlow.contentMode = UIViewContentModeScaleToFill;
        _aiBottomGlow.userInteractionEnabled = NO;
        _aiBottomGlow.alpha = 0;
        [self addSubview:_aiBottomGlow];
    }

    __weak typeof(self) ws = self;
    UIButton *(^mkStep)(NSString *, NSInteger) = ^UIButton *(NSString *title, NSInteger delta) {
        UIButtonConfiguration *cfg = [UIButtonConfiguration filledButtonConfiguration];
        cfg.title = title;
        cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        cfg.baseBackgroundColor = [UIColor colorWithWhite:1 alpha:0.15];
        cfg.baseForegroundColor = UIColor.whiteColor;
        cfg.contentInsets = NSDirectionalEdgeInsetsMake(6, 6, 6, 6);
        cfg.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *inc) {
            NSMutableDictionary *d = [inc mutableCopy];
            d[NSFontAttributeName] = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold];
            return d;
        };
        return [UIButton buttonWithConfiguration:cfg primaryAction:[UIAction actionWithHandler:^(UIAction *a) {
            [ws adjustAMOffset:delta];
        }]];
    };
    _amOffsetLabel = [UILabel new];
    _amOffsetLabel.textColor = UIColor.whiteColor;
    _amOffsetLabel.font = [UIFont monospacedDigitSystemFontOfSize:13.5 weight:UIFontWeightBold];
    _amOffsetLabel.textAlignment = NSTextAlignmentCenter;
    _amOffsetLabel.userInteractionEnabled = YES;
    [_amOffsetLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(resetAMOffset)]];
    [_amOffsetLabel.widthAnchor constraintGreaterThanOrEqualToConstant:58].active = YES;

    UIButton *closeOff = [UIButton buttonWithType:UIButtonTypeSystem];
    [closeOff setImage:[UIImage systemImageNamed:@"xmark" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightBold]] forState:UIControlStateNormal];
    closeOff.tintColor = IVLSecondary;
    [closeOff addTarget:self action:@selector(toggleAMOffsetPanel) forControlEvents:UIControlEventTouchUpInside];
    [closeOff.widthAnchor constraintEqualToConstant:28].active = YES;

    _amOffsetPanel = [[UIStackView alloc] initWithArrangedSubviews:@[
        mkStep(@"−0.5", -500), mkStep(@"−0.1", -100), _amOffsetLabel, mkStep(@"+0.1", 100), mkStep(@"+0.5", 500), closeOff
    ]];
    _amOffsetPanel.axis = UILayoutConstraintAxisHorizontal;
    _amOffsetPanel.spacing = 5;
    _amOffsetPanel.alignment = UIStackViewAlignmentCenter;
    _amOffsetPanel.distribution = UIStackViewDistributionFill;
    _amOffsetPanel.layoutMargins = UIEdgeInsetsMake(6, 10, 6, 8);
    _amOffsetPanel.layoutMarginsRelativeArrangement = YES;
    _amOffsetPanel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.86];
    _amOffsetPanel.layer.cornerRadius = 22;
    _amOffsetPanel.layer.cornerCurve = kCACornerCurveContinuous;
    _amOffsetPanel.layer.borderWidth = 0.75;
    _amOffsetPanel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.16].CGColor;
    _amOffsetPanel.alpha = 0;
    _amOffsetPanel.hidden = YES;
    [self addSubview:_amOffsetPanel];

    [self refreshAMTranslateButton];
    [self refreshAMOffsetUI];
}

#pragma mark - Audio Route (AirPods / Headphones / AirPlay)

- (void)routeChanged:(NSNotification *)n {
    dispatch_async(dispatch_get_main_queue(), ^{ [self updateAudioRoute]; });
}

- (void)updateAudioRoute {
    AVAudioSessionPortDescription *out = [AVAudioSession sharedInstance].currentRoute.outputs.firstObject;
    NSString *portType = out.portType ?: @"";
    NSString *portName = out.portName ?: @"";
    NSString *low = portName.lowercaseString;

    BOOL builtIn = !portType.length || [portType isEqualToString:AVAudioSessionPortBuiltInSpeaker] || [portType isEqualToString:AVAudioSessionPortBuiltInReceiver];
    NSArray<NSString *> *candidates;
    if ([low containsString:@"airpods max"]) {
        candidates = @[@"airpodsmax", @"headphones", @"airplayaudio"];
    } else if ([low containsString:@"airpods pro"]) {
        candidates = @[@"airpodspro", @"airpods", @"earbuds", @"headphones"];
    } else if ([low containsString:@"airpods"]) {
        candidates = @[@"airpods", @"airpodspro", @"earbuds", @"headphones"];
    } else if ([low containsString:@"beats"] || [low containsString:@"buds"]) {
        candidates = @[@"earbuds", @"headphones", @"airplayaudio"];
    } else if ([portType isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
               [portType isEqualToString:AVAudioSessionPortBluetoothLE] ||
               [portType isEqualToString:AVAudioSessionPortBluetoothHFP] ||
               [portType isEqualToString:AVAudioSessionPortHeadphones]) {
        candidates = @[@"airpodspro", @"headphones", @"airplayaudio"];
    } else {
        candidates = @[@"airplayaudio"];
    }

    NSString *chosen = @"airplayaudio";
    for (NSString *sym in candidates) {
        if ([UIImage systemImageNamed:sym]) { chosen = sym; break; }
    }
    [_routeBtn setSymbol:chosen size:19];
    _routeBtn.tintColor = builtIn ? IVLTertiary : IVLPrimary;
    _routeLabel.text = builtIn ? @"" : portName;
    _routeLabel.hidden = builtIn;
    [self setNeedsLayout];
}

- (void)routeTapped {
    [[UIImpactFeedbackGenerator new] impactOccurred];
    for (UIView *sub in _airplay.subviews) {
        if ([sub isKindOfClass:[UIButton class]]) {
            [(UIButton *)sub sendActionsForControlEvents:UIControlEventTouchUpInside];
            return;
        }
    }
}

#pragma mark - Settings & Mode Switching

- (void)settingsChanged:(NSNotification *)n {
    NSString *k = n.object;
    if (!k || [k isEqualToString:IVLKeyImmersivePlayer] || [k isEqualToString:IVLKeyAMLyrics]) {
        if (![self usesAMLyrics] && _lyricsMode) [self setLyricsMode:NO animated:NO];
        [self setNeedsLayout];
    }
    if (!k || [k isEqualToString:IVLKeyTranslation] || [k isEqualToString:IVLKeyTranslationEngine] || [k isEqualToString:IVLKeyPronunciation] || [k isEqualToString:IVLKeyShowBreaks]) {
        [[IVLAMLyricCell blurCache] removeAllObjects];
        [self refreshAMTranslateButton];
        [self refreshAppleIntelligenceGlow];
        [self reloadAMLyrics];
    }
    if (!k || [k isEqualToString:IVLKeySongOffsets] || [k isEqualToString:IVLKeyGlobalOffset]) {
        [self refreshAMOffsetUI];
        [self updateAMLyricsProgress];
    }
}

- (void)trackDidChange {
    IVLTrack *t = [IVLPlaybackManager shared].track;
    _shownVideoID = t.videoID;
    [self setArtwork:t.artworkImage];
    [self refreshAMOffsetUI];
    [self reloadAMLyrics];
}

- (void)artworkDidChange {
    UIImage *img = [IVLPlaybackManager shared].track.artworkImage;
    if (img) [self setArtwork:img];
}

- (void)setMoreMenu:(UIMenu *)menu { _moreMenu = menu; _more.menu = menu; }

- (void)setOnOpenProviderPicker:(void (^)(void))onOpenProviderPicker {
    _onOpenProviderPicker = [onOpenProviderPicker copy];
    [self refreshAMTranslateButton];
}

- (BOOL)isImmersive { return [IVLSettings boolForKey:IVLKeyImmersivePlayer]; }
- (BOOL)usesAMLyrics { return [self isImmersive] || [IVLSettings boolForKey:IVLKeyAMLyrics]; }
- (BOOL)isVideoShape { return _aspect > 1.12; }

- (void)toggleLyricsMode { [self setLyricsMode:!_lyricsMode animated:YES]; }

- (void)setLyricsMode:(BOOL)on animated:(BOOL)animated {
    if (on && ![self usesAMLyrics]) {
        if (self.onShowLyrics) self.onShowLyrics();
        return;
    }
    if (_lyricsMode == on) return;
    _lyricsMode = on;
    if (on) {
        _compactHeader.hidden = NO;
        _amStage.hidden = NO;
        _amTransBtn.hidden = _amOffsetVisible;
        _amSyncBtn.hidden = _amOffsetVisible;
        _amAIBtn.hidden = _amOffsetVisible;
        _amOffsetPanel.hidden = !_amOffsetVisible;
        _amFollowing = YES;
        _needsAMInitialScroll = YES;
        [self reloadAMLyrics];
        [self refreshAMOffsetUI];
        [self refreshAppleIntelligenceGlow];
    }
    [_lyricsBtn setSymbol:(on ? @"quote.bubble.fill" : @"quote.bubble") size:19];
    _lyricsBtn.tintColor = on ? [UIColor colorWithWhite:0.08 alpha:1.0] : IVLTertiary;

    void (^changes)(void) = ^{
        [self layoutSubviews];
        self->_compactHeader.alpha = on ? 1 : 0;
        self->_amStage.alpha = on ? 1 : 0;
        self->_amTransBtn.alpha = (on && !self->_amOffsetVisible) ? 1 : 0;
        self->_amSyncBtn.alpha = (on && !self->_amOffsetVisible) ? 1 : 0;
        self->_amAIBtn.alpha = (on && !self->_amOffsetVisible) ? 1 : 0;
        self->_amOffsetPanel.alpha = (on && self->_amOffsetVisible) ? 1 : 0;
        self->_lyricsDim.alpha = on ? 1 : 0;
        self->_lyricsActivePill.alpha = on ? 1 : 0;
        self->_artHost.alpha = on ? 0 : 1;
        self->_title.alpha = on ? 0 : 1;
        self->_artist.alpha = on ? 0 : 1;
        self->_lyric.alpha = on ? 0 : 1;
        self->_star.backgroundColor = on ? [UIColor colorWithWhite:1 alpha:0.14] : UIColor.clearColor;
        self->_more.backgroundColor = on ? [UIColor colorWithWhite:1 alpha:0.14] : UIColor.clearColor;
    };
    void (^done)(BOOL) = ^(BOOL f) {
        if (!self->_lyricsMode) {
            self->_compactHeader.hidden = YES;
            self->_amStage.hidden = YES;
            self->_amTransBtn.hidden = YES;
            self->_amSyncBtn.hidden = YES;
            self->_amAIBtn.hidden = YES;
            self->_amOffsetPanel.hidden = YES;
        } else {
            [self scrollAMToActiveAnimated:NO];
        }
    };
    if (animated) {
        [UIView animateWithDuration:0.42 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0 options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState animations:changes completion:done];
    } else {
        changes();
        done(YES);
    }
    if (self.onLyricsModeChanged) self.onLyricsModeChanged();
}

- (void)compactHeaderTapped {
    if (_lyricsMode) {
        [[UIImpactFeedbackGenerator new] impactOccurred];
        [self setLyricsMode:NO animated:YES];
    }
}

#pragma mark - Dedicated Apple Music Lyrics Logic

- (void)refreshAMTranslateButton {
    BOOL trOn = [IVLSettings boolForKey:IVLKeyTranslation];
    NSInteger pron = [IVLSettings integerForKey:IVLKeyPronunciation];
    BOOL anyOn = trOn || pron != 0;

    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:15.5 weight:UIImageSymbolWeightSemibold];
    UIImage *sym = [UIImage systemImageNamed:@"translate" withConfiguration:cfg]
                ?: [UIImage systemImageNamed:@"character.bubble" withConfiguration:cfg]
                ?: [UIImage systemImageNamed:@"sparkles" withConfiguration:cfg];
    [_amTransBtn setImage:[sym imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
    _amTransBtn.backgroundColor = anyOn ? IVLPrimary : [UIColor colorWithWhite:1 alpha:0.16];
    _amTransBtn.tintColor = anyOn ? [UIColor colorWithWhite:0.08 alpha:1.0] : IVLPrimary;

    __weak typeof(self) ws = self;
    UIAction *trAct = [UIAction actionWithTitle:IVLLoc(@"translation") image:[UIImage systemImageNamed:@"character.bubble"] identifier:nil handler:^(UIAction *a) {
        [IVLSettings setBool:![IVLSettings boolForKey:IVLKeyTranslation] forKey:IVLKeyTranslation];
        [ws refreshAMTranslateButton];
    }];
    trAct.state = trOn ? UIMenuElementStateOn : UIMenuElementStateOff;

    NSArray *pronOpts = @[@[IVLLoc(@"off"), @0], @[IVLLoc(@"romaji"), @1], @[IVLLoc(@"kana"), @2]];
    NSMutableArray *pronChildren = [NSMutableArray array];
    for (NSArray *o in pronOpts) {
        UIAction *pa = [UIAction actionWithTitle:o[0] image:nil identifier:nil handler:^(UIAction *a) {
            [IVLSettings setObject:o[1] forKey:IVLKeyPronunciation];
            [ws refreshAMTranslateButton];
        }];
        pa.state = ([o[1] integerValue] == pron) ? UIMenuElementStateOn : UIMenuElementStateOff;
        [pronChildren addObject:pa];
    }
    UIMenu *pronMenu = [UIMenu menuWithTitle:IVLLoc(@"pronunciation") image:[UIImage systemImageNamed:@"textformat.abc"] identifier:nil options:0 children:pronChildren];

    UIAction *audioAct = [UIAction actionWithTitle:IVLLoc(@"menu_audio") image:[UIImage systemImageNamed:@"slider.horizontal.3"] identifier:nil handler:^(UIAction *a) {
        UIViewController *top = IVLTopViewController();
        if (top) [IVLAudioDSP presentQuickSheetFrom:top];
    }];
    UIAction *tvAct = [UIAction actionWithTitle:IVLLoc(@"menu_tv") image:[UIImage systemImageNamed:@"airplayvideo"] identifier:nil handler:^(UIAction *a) {
        UIViewController *top = IVLTopViewController();
        if (top) [IVLExternalDisplayManager presentQuickSheetFrom:top];
    }];
    UIAction *syncAct = [UIAction actionWithTitle:IVLLoc(@"sync") image:[UIImage systemImageNamed:@"timer"] identifier:nil handler:^(UIAction *a) {
        [ws toggleAMOffsetPanel];
    }];
    if ([[IVLPlaybackManager shared] songOffsetMs] != 0 || _amOffsetVisible) syncAct.state = UIMenuElementStateOn;

    UIMenu *quickGrid = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[audioAct, tvAct, syncAct]];
    if (@available(iOS 16.0, *)) {
        quickGrid.preferredElementSize = UIMenuElementSizeMedium;
    }

    NSMutableArray *langItems = [NSMutableArray arrayWithObjects:trAct, nil];
    if (IVLIsAppleIntelligenceAvailable()) {
        BOOL aiOn = trOn && [IVLSettings integerForKey:IVLKeyTranslationEngine] == IVLTranslationEngineAppleIntelligence;
        UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(20, 20)];
        UIImage *menuIcon = [[r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 20, 20) cornerRadius:5.0] addClip];
            [IVLAppleIntelligenceIconImage() drawInRect:CGRectMake(0, 0, 20, 20)];
        }] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
        UIAction *aiAct = [UIAction actionWithTitle:IVLLoc(@"tr_ai_btn") image:menuIcon identifier:nil handler:^(UIAction *a) {
            [ws amAITranslateTapped];
        }];
        aiAct.state = aiOn ? UIMenuElementStateOn : UIMenuElementStateOff;
        [langItems addObject:aiAct];
    }
    [langItems addObject:pronMenu];
    if (self.onOpenProviderPicker) {
        UIAction *srcAct = [UIAction actionWithTitle:IVLLoc(@"menu_source") image:[UIImage systemImageNamed:@"globe"] identifier:nil handler:^(UIAction *a) {
            if (ws.onOpenProviderPicker) ws.onOpenProviderPicker();
        }];
        NSString *srcName = [IVLPlaybackManager shared].lyrics.source;
        if (srcName.length) srcAct.subtitle = srcName;
        [langItems addObject:srcAct];
    }
    UIMenu *langSection = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:langItems];
    _amTransBtn.menu = [UIMenu menuWithTitle:@"" children:@[quickGrid, langSection]];
}

- (void)amAITranslateTapped {
    if (!IVLIsAppleIntelligenceAvailable()) return;
    [[UIImpactFeedbackGenerator new] impactOccurred];
    BOOL trOn = [IVLSettings boolForKey:IVLKeyTranslation];
    BOOL isAI = [IVLSettings integerForKey:IVLKeyTranslationEngine] == IVLTranslationEngineAppleIntelligence;
    if (trOn && isAI) {
        [IVLSettings setBool:NO forKey:IVLKeyTranslation];
    } else {
        [IVLSettings setObject:@(IVLTranslationEngineAppleIntelligence) forKey:IVLKeyTranslationEngine];
        [IVLSettings setBool:YES forKey:IVLKeyTranslation];
    }
    [self refreshAMTranslateButton];
    [self refreshAppleIntelligenceGlow];
}

- (void)refreshAppleIntelligenceGlow {
    if (!_aiTopGlow || !_aiBottomGlow) return;
    BOOL aiActive = IVLIsAppleIntelligenceAvailable()
                 && [IVLSettings boolForKey:IVLKeyTranslation]
                 && [IVLSettings integerForKey:IVLKeyTranslationEngine] == IVLTranslationEngineAppleIntelligence;
    if (_amAIBtn) {
        _amAIBtn.layer.borderWidth = aiActive ? 2.0 : 0.0;
        _amAIBtn.layer.borderColor = aiActive ? UIColor.whiteColor.CGColor : UIColor.clearColor.CGColor;
    }
    [self bringSubviewToFront:_aiTopGlow];
    [self bringSubviewToFront:_aiBottomGlow];
    [UIView animateWithDuration:0.35 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
        self->_aiTopGlow.alpha = aiActive ? 0.96 : 0.0;
        self->_aiBottomGlow.alpha = aiActive ? 0.96 : 0.0;
    } completion:nil];
}

- (void)refreshAMOffsetUI {
    NSInteger ms = [[IVLPlaybackManager shared] songOffsetMs];
    _amOffsetLabel.text = [NSString stringWithFormat:@"%+.1fs", ms / 1000.0];
    _amOffsetLabel.accessibilityHint = IVLLoc(@"reset");
    BOOL active = _amOffsetVisible || ms != 0;
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:15.5 weight:UIImageSymbolWeightSemibold];
    UIImage *sym = [UIImage systemImageNamed:@"timer" withConfiguration:cfg];
    [_amSyncBtn setImage:[sym imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
    _amSyncBtn.backgroundColor = active ? IVLPrimary : [UIColor colorWithWhite:1 alpha:0.16];
    _amSyncBtn.tintColor = active ? [UIColor colorWithWhite:0.08 alpha:1.0] : IVLPrimary;
}

- (void)toggleAMOffsetPanel {
    _amOffsetVisible = !_amOffsetVisible;
    [self refreshAMOffsetUI];
    if (!_lyricsMode) return;
    if (_amOffsetVisible) {
        _amOffsetPanel.hidden = NO;
        _amOffsetPanel.alpha = 0;
    } else {
        _amTransBtn.hidden = NO;
        _amSyncBtn.hidden = NO;
        _amAIBtn.hidden = NO;
    }
    [UIView animateWithDuration:0.24 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
        self->_amOffsetPanel.alpha = self->_amOffsetVisible ? 1 : 0;
        self->_amTransBtn.alpha = self->_amOffsetVisible ? 0 : 1;
        self->_amSyncBtn.alpha = self->_amOffsetVisible ? 0 : 1;
        self->_amAIBtn.alpha = self->_amOffsetVisible ? 0 : 1;
    } completion:^(BOOL f) {
        if (self->_amOffsetVisible) {
            self->_amTransBtn.hidden = YES;
            self->_amSyncBtn.hidden = YES;
            self->_amAIBtn.hidden = YES;
        } else {
            self->_amOffsetPanel.hidden = YES;
        }
    }];
}

- (void)adjustAMOffset:(NSInteger)delta {
    IVLPlaybackManager *m = [IVLPlaybackManager shared];
    [m setSongOffsetMs:[m songOffsetMs] + delta];
    [[UISelectionFeedbackGenerator new] selectionChanged];
    [self refreshAMOffsetUI];
    [self updateAMLyricsProgress];
}

- (void)resetAMOffset {
    [[IVLPlaybackManager shared] setSongOffsetMs:0];
    [[UIImpactFeedbackGenerator new] impactOccurred];
    [self refreshAMOffsetUI];
    [self updateAMLyricsProgress];
}

- (void)reloadAMLyrics {
    IVLPlaybackManager *m = [IVLPlaybackManager shared];
    IVLLyrics *ly = m.lyrics;
    BOOL showBreaks = [IVLSettings boolForKey:IVLKeyShowBreaks];
    NSMutableArray<IVLLyricLine *> *lines = [NSMutableArray array];
    for (IVLLyricLine *l in ly.lines) if (showBreaks || !l.instrumental) [lines addObject:l];
    _amLines = lines;
    _amSynced = ly.synced;

    BOOL hasLines = lines.count > 0;
    _amTable.hidden = !hasLines;
    if (!hasLines) {
        IVLLyricsState s = m.track ? m.state : IVLLyricsStateIdle;
        BOOL loading = (s == IVLLyricsStateLoading);
        loading ? [_amSpinner startAnimating] : [_amSpinner stopAnimating];
        _amSpinner.hidden = !loading;
        _amStateLabel.hidden = loading;
        _amStateLabel.text = (s == IVLLyricsStateError) ? IVLLoc(@"error") : IVLLoc(@"not_found");
    } else {
        [_amSpinner stopAnimating];
        _amSpinner.hidden = YES;
        _amStateLabel.hidden = YES;
    }

    BOOL same = (ly != nil && ly == _amShownLyrics);
    _amShownLyrics = ly;
    _amActiveIndex = -1;
    [[IVLAMLyricCell blurCache] removeAllObjects];
    [_amTable reloadData];
    if (_lyricsMode && hasLines && !same) {
        _amFollowing = YES;
        [_amTable layoutIfNeeded];
        [self updateAMLyricsProgress];
        [self scrollAMToActiveAnimated:NO];
    }
}

- (NSInteger)amIndexForTime:(NSInteger)ms {
    NSInteger lo = 0, hi = (NSInteger)_amLines.count - 1, found = -1;
    while (lo <= hi) {
        NSInteger mid = (lo + hi) / 2;
        if (_amLines[mid].startMs <= ms) { found = mid; lo = mid + 1; } else hi = mid - 1;
    }
    return found;
}

- (NSInteger)tierForRow:(NSInteger)row active:(NSInteger)active {
    if (!_amSynced) return 0;
    if (active < 0) return row == 0 ? 1 : 2;
    NSInteger dist = labs(row - active);
    if (dist == 0) return 0;
    return dist == 1 ? 1 : 2;
}

- (void)updateAMLyricsProgress {
    if (!_lyricsMode || !_amSynced || !_amLines.count || _amTable.hidden) return;
    NSInteger ms = [[IVLPlaybackManager shared] currentTimeMs];
    NSInteger idx = [self amIndexForTime:ms];
    if (idx != _amActiveIndex) {
        _amActiveIndex = idx;
        for (IVLAMLyricCell *cell in _amTable.visibleCells) {
            NSIndexPath *ip = [_amTable indexPathForCell:cell];
            if (ip) [cell setTier:[self tierForRow:ip.row active:idx] animated:YES];
        }
        if (_amFollowing) [self scrollAMToActiveAnimated:YES];
    }
    if (idx >= 0 && idx < (NSInteger)_amLines.count) {
        IVLAMLyricCell *activeCell = (IVLAMLyricCell *)[_amTable cellForRowAtIndexPath:[NSIndexPath indexPathForRow:idx inSection:0]];
        [activeCell updateTime:ms];
    }
}

- (void)scrollAMToActiveAnimated:(BOOL)animated {
    if (!_amLines.count || _amTable.bounds.size.height <= 0) return;
    if (_amActiveIndex < 0 || _amActiveIndex >= (NSInteger)_amLines.count) {
        [_amTable setContentOffset:CGPointMake(0, -_amTable.contentInset.top) animated:animated];
        return;
    }
    CGRect r = [_amTable rectForRowAtIndexPath:[NSIndexPath indexPathForRow:_amActiveIndex inSection:0]];
    CGFloat h = _amTable.bounds.size.height;
    CGFloat y = r.origin.y - h * 0.24;
    CGFloat minY = -_amTable.contentInset.top;
    CGFloat maxY = MAX(minY, _amTable.contentSize.height + _amTable.contentInset.bottom - h);
    y = MAX(minY, MIN(maxY, y));
    [_amTable setContentOffset:CGPointMake(0, y) animated:animated];
}

- (void)scheduleAMResume {
    [_amResumeTimer invalidate];
    NSInteger sec = [IVLSettings integerForKey:IVLKeyAutoResume];
    if (sec <= 0 || !_amSynced) return;
    __weak typeof(self) ws = self;
    _amResumeTimer = [NSTimer scheduledTimerWithTimeInterval:sec repeats:NO block:^(NSTimer *t) {
        __strong typeof(ws) ss = ws;
        if (!ss) return;
        ss->_amFollowing = YES;
        [ss scrollAMToActiveAnimated:YES];
    }];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    if (scrollView != _amTable || !_amSynced) return;
    _amFollowing = NO;
    [_amResumeTimer invalidate];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (scrollView == _amTable && !decelerate) [self scheduleAMResume];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if (scrollView == _amTable) [self scheduleAMResume];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _amLines.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    IVLAMLyricCell *c = [tableView dequeueReusableCellWithIdentifier:[IVLAMLyricCell reuseID] forIndexPath:indexPath];
    BOOL karaoke = [IVLSettings boolForKey:IVLKeyKaraoke];
    [c configureWithLine:_amLines[indexPath.row] synced:_amSynced karaoke:karaoke tier:[self tierForRow:indexPath.row active:_amActiveIndex]];
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!_amSynced || indexPath.row >= (NSInteger)_amLines.count) return;
    IVLLyricLine *l = _amLines[indexPath.row];
    [[IVLPlaybackManager shared] seekToMs:l.startMs];
    [[UIImpactFeedbackGenerator new] impactOccurred];
    _amFollowing = YES;
    [_amResumeTimer invalidate];
    [self updateAMLyricsProgress];
    [self scrollAMToActiveAnimated:YES];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    if (indexPath.row >= (NSInteger)_amLines.count) return nil;
    IVLLyricLine *l = _amLines[indexPath.row];
    if (l.instrumental) return nil;
    BOOL synced = _amSynced;
    __weak typeof(self) ws = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *suggested) {
        NSMutableArray *a = [NSMutableArray array];
        if (synced) {
            [a addObject:[UIAction actionWithTitle:IVLLoc(@"play_from_here") image:[UIImage systemImageNamed:@"play.fill"] identifier:nil handler:^(UIAction *x) {
                [[IVLPlaybackManager shared] seekToMs:l.startMs];
                __strong typeof(ws) ss = ws;
                if (ss) { ss->_amFollowing = YES; [ss scrollAMToActiveAnimated:YES]; }
            }]];
            [a addObject:[UIAction actionWithTitle:IVLLoc(@"sync_here") image:[UIImage systemImageNamed:@"scope"] identifier:nil handler:^(UIAction *x) {
                IVLPlaybackManager *m = [IVLPlaybackManager shared];
                NSInteger song = l.startMs - [m rawTimeMs] - [IVLSettings integerForKey:IVLKeyGlobalOffset];
                [m setSongOffsetMs:song];
            }]];
        }
        [a addObject:[UIAction actionWithTitle:IVLLoc(@"copy_line") image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *x) {
            NSMutableArray *parts = [NSMutableArray arrayWithObject:l.text ?: @""];
            if (l.pronunciation.length) [parts addObject:l.pronunciation];
            if (l.translation.length) [parts addObject:l.translation];
            UIPasteboard.generalPasteboard.string = [parts componentsJoinedByString:@"\n"];
        }]];
        return [UIMenu menuWithTitle:@"" children:a];
    }];
}

#pragma mark - Atmosphere

- (void)setArtwork:(UIImage *)image {
    NSString *key = image ? [NSString stringWithFormat:@"%p_%.0fx%.0f", image, image.size.width, image.size.height] : @"";
    if ([key isEqualToString:_imageKey]) return;
    _imageKey = key;
    _hero.image = image;
    _compactArt.image = image;
    CGFloat a = (image && image.size.height > 0) ? image.size.width / image.size.height : 1;
    _aspect = fabs(a - 1) < 0.08 ? 1 : MAX(0.4, MIN(2.4, a));
    if (!image) { _heroBlur.image = nil; [self setNeedsLayout]; return; }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *blurred = nil;
        @try {
            CIImage *ci = image.CIImage ?: (image.CGImage ? [CIImage imageWithCGImage:image.CGImage] : nil);
            if (ci) {
                CGFloat scale = 360.0 / MAX(1, ci.extent.size.width);
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

#pragma mark - Layout

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    if (W <= 0 || H <= 0) return;
    UIEdgeInsets safe = self.safeAreaInsets;
    CGFloat inner = W - kPad * 2;
    BOOL immersive = [self isImmersive];
    BOOL inLyrics = [self usesAMLyrics] && _lyricsMode;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _mesh.frame = self.bounds;
    _lyricsDim.frame = self.bounds;

    // ---- bottom control deck (compact spacing in _lyricsMode to maximize the Apple Music lyrics viewport)
    CGFloat y = H - MAX(safe.bottom, 12) - (inLyrics ? 4 : 6);
    CGFloat footerH = 44;
    y -= footerH;
    CGFloat third = inner / 3;
    _lyricsBtn.frame = CGRectMake(kPad + (third - 44) / 2, y - (inLyrics ? 2 : 0), 44, 44);
    _lyricsActivePill.frame = CGRectMake(CGRectGetMidX(_lyricsBtn.frame) - 19, CGRectGetMidY(_lyricsBtn.frame) - 16, 38, 32);

    BOOL hasRouteName = !_routeLabel.hidden && _routeLabel.text.length > 0;
    CGFloat routeCenterX = kPad + third + third * 0.5;
    _routeBtn.frame = CGRectMake(routeCenterX - 22, y - (hasRouteName ? 5 : 0), 44, 38);
    _airplay.frame = _routeBtn.frame;
    _routeLabel.frame = CGRectMake(routeCenterX - 72, CGRectGetMaxY(_routeBtn.frame) - 4, 144, 13);

    _queueBtn.frame = CGRectMake(kPad + third * 2 + (third - 44) / 2, y - (inLyrics ? 2 : 0), 44, 44);
    _badge.frame = CGRectMake(CGRectGetMaxX(_queueBtn.frame) - 12, CGRectGetMinY(_queueBtn.frame) + 9, 6, 6);

    y -= (inLyrics ? 14 : 22);
    CGFloat volH = 24;
    y -= volH;
    _volLow.frame = CGRectMake(kPad, y, 18, volH);
    _volHigh.frame = CGRectMake(W - kPad - 22, y, 22, volH);
    _volume.frame = CGRectMake(kPad + 26, y, inner - 26 - 30, volH);

    y -= (inLyrics ? 20 : 32);
    CGFloat transport = inLyrics ? 54 : 60;
    y -= transport;
    CGFloat cx = W / 2;
    _play.frame = CGRectMake(cx - 32, y, 64, transport);
    _prev.frame = CGRectMake(cx - 32 - 44 - 56, y, 56, transport);
    _next.frame = CGRectMake(cx + 32 + 44, y, 56, transport);

    y -= (inLyrics ? 18 : 30);
    _elapsed.frame = CGRectMake(kPad, y - 15, inner / 2, 15);
    _remaining.frame = CGRectMake(kPad + inner / 2, y - 15, inner / 2, 15);
    y -= 15 + 4;
    _seek.frame = CGRectMake(kPad, y - 22, inner, 22);
    CGFloat seekTop = y - 22;

    y = seekTop - 10;
    _lyric.frame = CGRectMake(kPad, y - 20, inner, 20);
    y -= 20 + 12;
    CGFloat actions = 34 * 2 + 4;
    _artist.frame = CGRectMake(kPad, y - 23, inner - actions - 8, 23);
    y -= 23 + 3;
    _title.frame = CGRectMake(kPad, y - 27, inner - actions - 8, 27);
    CGFloat deckTop = y - 27;

    // ---- compact header & Apple Music lyrics stage frames
    CGFloat headerTop = safe.top + 16;
    CGFloat headerH = 48;
    _compactHeader.frame = CGRectMake(kPad, headerTop, inner - 74, headerH);
    _compactArt.frame = CGRectMake(0, 0, 48, 48);
    CGFloat ctX = 60, ctW = MAX(40, _compactHeader.bounds.size.width - ctX);
    _compactTitle.frame = CGRectMake(ctX, 5, ctW, 20);
    _compactArtist.frame = CGRectMake(ctX, 26, ctW, 17);

    if (inLyrics) {
        _more.frame = CGRectMake(W - kPad - 30, headerTop + 9, 30, 30);
        _star.frame = CGRectMake(CGRectGetMinX(_more.frame) - 38, headerTop + 9, 30, 30);
        _more.layer.cornerRadius = 15;
        _star.layer.cornerRadius = 15;
    } else {
        _more.frame = CGRectMake(W - kPad - 34 + 6, deckTop + 8, 34, 34);
        _star.frame = CGRectMake(CGRectGetMinX(_more.frame) - 36, deckTop + 8, 34, 34);
        _more.layer.cornerRadius = 17;
        _star.layer.cornerRadius = 17;
    }

    CGFloat stageTop = headerTop + headerH + 8;
    CGFloat stageBottom = seekTop - 8;
    CGFloat stageH = MAX(60, stageBottom - stageTop);
    _amStage.frame = CGRectMake(0, stageTop, W, stageH);
    _amTable.frame = _amStage.bounds;
    _amFadeMask.frame = _amStage.bounds;
    _amSpinner.center = CGPointMake(W * 0.5, stageH * 0.5);
    _amStateLabel.frame = CGRectMake(kPad, stageH * 0.5 - 30, inner, 60);
    UIEdgeInsets amInset = _amSynced ? UIEdgeInsetsMake(stageH * 0.24, 0, stageH * 0.58, 0) : UIEdgeInsetsMake(20, 0, 64, 0);
    if (!UIEdgeInsetsEqualToEdgeInsets(_amTable.contentInset, amInset)) _amTable.contentInset = amInset;
    _amTransBtn.frame = CGRectMake(W - kPad - 36, stageBottom - 40, 36, 36);
    _amSyncBtn.frame = CGRectMake(CGRectGetMinX(_amTransBtn.frame) - 44, stageBottom - 40, 36, 36);
    if (_amAIBtn) {
        _amAIBtn.frame = CGRectMake(CGRectGetMinX(_amSyncBtn.frame) - 44, stageBottom - 40, 36, 36);
    }
    CGFloat offW = MIN(inner, 348);
    _amOffsetPanel.frame = CGRectMake((W - offW) * 0.5, stageBottom - 44, offW, 44);
    if (_aiTopGlow && _aiBottomGlow) {
        CGFloat glowH = 42;
        _aiTopGlow.frame = CGRectMake(0, 0, W, glowH);
        _aiBottomGlow.frame = CGRectMake(0, H - glowH, W, glowH);
        [self bringSubviewToFront:_aiTopGlow];
        [self bringSubviewToFront:_aiBottomGlow];
    }

    if (inLyrics) {
        if ([self.subviews indexOfObject:_heroBlur] > [self.subviews indexOfObject:_lyricsDim]) {
            [self insertSubview:_heroBlur belowSubview:_lyricsDim];
        }
        _heroBlur.frame = self.bounds;
        _heroBlur.alpha = 0.62;
        _heroBlur.layer.mask = nil;
    } else if (immersive) {
        // ---- Experimental: Apple Music (v27) full-bleed artwork + progressive optical dissolve
        if ([self.subviews indexOfObject:_heroBlur] < [self.subviews indexOfObject:_artHost]) {
            [self insertSubview:_heroBlur aboveSubview:_artHost];
        }
        _artHost.transform = CGAffineTransformIdentity;
        _artHost.frame = self.bounds;
        _artHost.layer.shadowOpacity = 0;

        CGFloat dissolveStart = deckTop - H * 0.10, dissolveEnd = deckTop + H * 0.07;
        CGRect hero;
        if ([self isVideoShape]) {
            CGFloat h = W / _aspect;
            hero = CGRectMake(0, MAX(safe.top + 24, (dissolveStart - h) / 2 + safe.top / 2), W, h);
        } else {
            hero = CGRectMake(0, 0, W, MAX(dissolveEnd, W / MAX(0.4, _aspect)));
        }
        _hero.frame = hero;
        _hero.layer.cornerRadius = 0;
        _hero.layer.mask = _heroMask;
        _heroMask.frame = _hero.bounds;
        CGFloat hh = MAX(1, hero.size.height);
        if ([self isVideoShape]) {
            _heroMask.colors = @[(id)UIColor.clearColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor];
            _heroMask.locations = @[@0, @0.06, @0.82, @1];
        } else {
            _heroMask.colors = @[(id)UIColor.blackColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor];
            _heroMask.locations = @[@0, @(MIN(0.99, MAX(0, (dissolveStart - hero.origin.y) / hh))), @(MIN(1, MAX(0.01, (dissolveEnd - hero.origin.y) / hh)))];
        }
        _heroBlur.frame = self.bounds;
        _heroBlur.alpha = 1.0;
        _heroBlur.layer.mask = _blurMask;
        _blurMask.frame = _heroBlur.bounds;
        CGFloat bs = MAX(0, ([self isVideoShape] ? CGRectGetMaxY(hero) - hero.size.height * 0.35 : dissolveStart) / H);
        _blurMask.colors = @[(id)UIColor.clearColor.CGColor, (id)UIColor.blackColor.CGColor, (id)[UIColor colorWithWhite:0 alpha:0.55].CGColor];
        _blurMask.locations = @[@(MIN(0.98, bs)), @(MIN(0.99, MAX(bs + 0.01, dissolveEnd / H))), @1];
    } else {
        // ---- Default: standard framed 1:1 cover (song) or 16:9 thumbnail (video)
        if ([self.subviews indexOfObject:_heroBlur] > [self.subviews indexOfObject:_artHost]) {
            [self insertSubview:_heroBlur belowSubview:_artHost];
        }
        _heroBlur.frame = self.bounds;
        _heroBlur.alpha = 0.42;
        _heroBlur.layer.mask = nil;
        _hero.layer.mask = nil;

        CGFloat top = safe.top + 22;
        CGFloat bottom = deckTop - 20;
        CGFloat availH = MAX(60, bottom - top);
        CGRect card;
        CGFloat radius;
        if ([self isVideoShape]) {
            CGFloat videoAspect = 16.0 / 9.0;
            CGFloat w = MIN(W - 36, availH * videoAspect);
            CGFloat h = w / videoAspect;
            card = CGRectMake((W - w) * 0.5, top + (availH - h) * 0.5, w, h);
            radius = 12;
        } else {
            CGFloat side = MIN(inner, availH);
            card = CGRectMake((W - side) * 0.5, top + (availH - side) * 0.5, side, side);
            radius = 14;
        }
        _artHost.transform = CGAffineTransformIdentity;
        _artHost.frame = card;
        _hero.frame = _artHost.bounds;
        _hero.layer.cornerRadius = radius;
        _artHost.layer.shadowOpacity = (_shownPlaying || [self isVideoShape]) ? 0.42f : 0.18f;
        _artHost.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_artHost.bounds cornerRadius:radius].CGPath;
        if (!_shownPlaying && ![self isVideoShape]) {
            _artHost.transform = CGAffineTransformMakeScale(0.86, 0.86);
        }
    }
    [CATransaction commit];

    _grabber.frame = CGRectMake((W - 36) / 2, safe.top + 6, 36, 4);

    if (inLyrics && _needsAMInitialScroll && _amTable.bounds.size.height > 40 && _amLines.count) {
        _needsAMInitialScroll = NO;
        [_amTable layoutIfNeeded];
        [self updateAMLyricsProgress];
        [self scrollAMToActiveAnimated:NO];
    }
}

#pragma mark - Refresh

- (void)refresh {
    IVLPlaybackManager *m = [IVLPlaybackManager shared];
    IVLTrack *t = m.track;
    NSString *vid = t.videoID ?: @"";
    if (![vid isEqualToString:_shownVideoID ?: @""]) {
        _shownVideoID = vid;
        [self setArtwork:t.artworkImage];
        [self refreshAMOffsetUI];
    } else if (t.artworkImage && _hero.image != t.artworkImage) {
        [self setArtwork:t.artworkImage];
    }
    NSString *title = t.title ?: @"";
    if (![title isEqualToString:_title.attributedText.string ?: @""]) {
        _title.attributedText = [[NSAttributedString alloc] initWithString:title attributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:21 weight:UIFontWeightBold],
            NSForegroundColorAttributeName: IVLPrimary,
            NSKernAttributeName: @(-0.42),
        }];
        _compactTitle.text = title;
    }
    _artist.text = t.artist;
    _compactArtist.text = t.artist;

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

    if (_lyricsMode) {
        [self updateAMLyricsProgress];
    }

    BOOL playing = [IVLRemoteControl isPlaying];
    if (playing != _shownPlaying) {
        _shownPlaying = playing;
        [_play setSymbol:playing ? @"pause.fill" : @"play.fill" size:44];
        if (![self isImmersive] && ![self isVideoShape]) {
            [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.72 initialSpringVelocity:0 options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState animations:^{
                self->_artHost.transform = playing ? CGAffineTransformIdentity : CGAffineTransformMakeScale(0.86, 0.86);
                self->_artHost.layer.shadowOpacity = playing ? 0.42f : 0.18f;
            } completion:nil];
        }
    }
    _star.hidden = ![IVLRemoteControl canLike];
    _badge.hidden = ![IVLSleepTimer shared].active;
}

#pragma mark - Volume

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

#pragma mark - Actions & Gestures

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
        [_star setSymbol:@"star.fill" size:16];
        [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
    }
}

- (void)artTapped {
    [[UIImpactFeedbackGenerator new] impactOccurred];
    if ([self usesAMLyrics]) {
        [self setLyricsMode:YES animated:YES];
    } else if (self.onShowLyrics) {
        self.onShowLyrics();
    }
}

- (void)lyricsTapped {
    [[UIImpactFeedbackGenerator new] impactOccurred];
    if ([self usesAMLyrics]) {
        [self toggleLyricsMode];
    } else if (self.onShowLyrics) {
        self.onShowLyrics();
    }
}

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

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer == _artTap) {
        if (_lyricsMode) return NO;
        if ([self isImmersive]) {
            CGPoint p = [touch locationInView:self];
            return p.y > self.safeAreaInsets.top + 16 && p.y < CGRectGetMinY(_title.frame) - 8;
        }
        return YES;
    }
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (g != _pan) return [super gestureRecognizerShouldBegin:g];
    CGPoint v = [_pan velocityInView:self];
    CGPoint p = [_pan locationInView:self];
    if (_lyricsMode) {
        return v.y > fabs(v.x) && p.y <= CGRectGetMaxY(_compactHeader.frame) + 8;
    }
    return v.y > fabs(v.x) && p.y < CGRectGetMinY(_title.frame);
}

@end
