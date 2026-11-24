#import "IVLFloatingButton.h"
#import "IVLLyricsViewController.h"
#import "IVLPlaybackManager.h"
#import "IVLSettings.h"
#import "IVLLocalization.h"
#import "YTMHeaders.h"

static const CGFloat kSize = 44;
static const CGFloat kEdge = 8;

@implementation IVLFloatingButton {
    UIVisualEffectView *_blur;
    UIImageView *_icon;
    UILabel *_label;
    NSTimer *_timer;
    NSString *_shownText;
    CGPoint _dragStartCenter;
    BOOL _dragging;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.accessibilityLabel = IVLLoc(@"lyrics");
        self.accessibilityHint = IVLLoc(@"button_hint");
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;

        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.25;
        self.layer.shadowRadius = 8;
        self.layer.shadowOffset = CGSizeMake(0, 2);

        _blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
        _blur.layer.cornerRadius = kSize / 2;
        _blur.clipsToBounds = YES;
        _blur.userInteractionEnabled = NO;
        [self addSubview:_blur];

        _icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"quote.bubble.fill"
                                                           withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold]]];
        _icon.tintColor = UIColor.whiteColor;
        _icon.contentMode = UIViewContentModeCenter;
        [self addSubview:_icon];

        _label = [UILabel new];
        _label.textColor = UIColor.whiteColor;
        _label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        _label.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:_label];

        [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tap)]];
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPress:)];
        lp.minimumPressDuration = 0.6;
        [self addGestureRecognizer:lp];
        [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(settingsChanged:) name:IVLSettingsDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(update) name:IVLLyricsDidChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_timer invalidate];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [_timer invalidate];
    _timer = nil;
    if (self.window) {
        __weak typeof(self) ws = self;
        _timer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) { [ws update]; }];
        [self update];
    }
}

- (void)settingsChanged:(NSNotification *)n {
    NSString *k = n.object;
    if ([k isEqualToString:IVLKeyShowButton] || [k isEqualToString:IVLKeyMiniLyric] || [k isEqualToString:IVLKeyEnabled]) {
        _shownText = nil;
        [self update];
    }
}

- (BOOL)wantsVisible {
    return [IVLSettings boolForKey:IVLKeyEnabled] && [IVLSettings boolForKey:IVLKeyShowButton];
}

- (void)update {
    self.hidden = ![self wantsVisible];
    if (self.hidden || _dragging) return;
    NSString *text = nil;
    if ([IVLSettings boolForKey:IVLKeyMiniLyric]) {
        IVLPlaybackManager *m = [IVLPlaybackManager shared];
        text = [m currentLineText];
        if (!text.length && m.state == IVLLyricsStateLoaded && m.lyrics.lines.count) text = @"♪";
    }
    if ([(text ?: @"") isEqualToString:(_shownText ?: @"")] && self.superview && self.frame.size.width > 0) return;
    _shownText = text;
    [UIView transitionWithView:_label duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction animations:^{
        self->_label.text = text;
    } completion:nil];
    self.accessibilityValue = text;
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
        [self relayout];
    } completion:nil];
}

/// Position is stored as the icon centre in 0..1 of the host bounds.
- (void)relayout {
    UIView *host = self.superview;
    if (!host) return;
    CGRect b = host.bounds;
    UIEdgeInsets safe = host.safeAreaInsets;
    CGFloat x = [IVLSettings doubleForKey:IVLKeyButtonX] * b.size.width;
    CGFloat y = [IVLSettings doubleForKey:IVLKeyButtonY] * b.size.height;
    BOOL anchorRight = x > b.size.width / 2;

    CGFloat textW = 0;
    if (_shownText.length) {
        CGFloat maxText = b.size.width * 0.72 - kSize;
        textW = MIN(maxText, ceil([_label sizeThatFits:CGSizeMake(CGFLOAT_MAX, kSize)].width)) + 14;
    }
    CGFloat w = kSize + textW;
    CGFloat minX = anchorRight ? x + kSize / 2 - w : x - kSize / 2;
    minX = MAX(safe.left + kEdge, MIN(b.size.width - safe.right - kEdge - w, minX));
    CGFloat minY = MAX(safe.top + kEdge, MIN(b.size.height - safe.bottom - kEdge - kSize, y - kSize / 2));
    self.frame = CGRectMake(minX, minY, w, kSize);
    _blur.frame = self.bounds;
    CGFloat iconX = anchorRight ? w - kSize : 0;
    _icon.frame = CGRectMake(iconX, 0, kSize, kSize);
    _label.frame = anchorRight ? CGRectMake(14, 0, MAX(0, textW - 14), kSize) : CGRectMake(kSize, 0, MAX(0, textW - 14), kSize);
    _label.textAlignment = anchorRight ? NSTextAlignmentRight : NSTextAlignmentLeft;
}

#pragma mark Gestures

- (void)tap {
    [[UIImpactFeedbackGenerator new] impactOccurred];
    // Hand the player to the manager if the track callbacks were missed
    IVLPlaybackManager *m = [IVLPlaybackManager shared];
    if (!m.player) {
        for (UIViewController *vc = self.hostViewController.parentViewController; vc; vc = vc.parentViewController) {
            if ([vc respondsToSelector:@selector(playerViewController)]) {
                UIViewController *player = [(YTMWatchViewController *)vc playerViewController];
                if (player) [m playerDidActivateVideo:player];
                break;
            }
        }
    }
    [m refreshNow];
    UIViewController *host = self.hostViewController ?: IVLTopViewController();
    [IVLLyricsViewController presentFromViewController:host];
}

- (void)longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan || _dragging) return;
    [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
    IVLPresentSettings(self.hostViewController ?: IVLTopViewController());
}

- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *host = self.superview;
    if (!host) return;
    switch (g.state) {
        case UIGestureRecognizerStateBegan: {
            _dragging = YES;
            _dragStartCenter = self.center;
            [UIView animateWithDuration:0.15 animations:^{ self.transform = CGAffineTransformMakeScale(1.08, 1.08); }];
            break;
        }
        case UIGestureRecognizerStateChanged: {
            CGPoint t = [g translationInView:host];
            self.center = CGPointMake(_dragStartCenter.x + t.x, _dragStartCenter.y + t.y);
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            _dragging = NO;
            CGRect b = host.bounds;
            BOOL anchorRight = CGRectGetMidX(self.frame) > b.size.width / 2;
            CGFloat iconCX = anchorRight ? CGRectGetMaxX(self.frame) - kSize / 2 : CGRectGetMinX(self.frame) + kSize / 2;
            [IVLSettings setObject:@(MAX(0, MIN(1, iconCX / MAX(1, b.size.width)))) forKey:IVLKeyButtonX];
            [IVLSettings setObject:@(MAX(0, MIN(1, self.center.y / MAX(1, b.size.height)))) forKey:IVLKeyButtonY];
            [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0 options:0 animations:^{
                self.transform = CGAffineTransformIdentity;
                [self relayout];
            } completion:nil];
            break;
        }
        default: break;
    }
}

@end
