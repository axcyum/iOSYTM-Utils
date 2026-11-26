#import "IVLHomeBarLyrics.h"
#import "IVLSettings.h"
#import "IVLPlaybackManager.h"
#import "IVLLyricsViewController.h"
#import "IVLExtras.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat kIVLHomeBarHeight = 26.0;

@implementation IVLHomeBarLyricsManager {
    BOOL _started;
    NSTimer *_timer;
    __weak UIView *_attachedMiniBar;
    BOOL _savedClipsToBounds;
    UIView *_stripView;
    UIView *_topHairline;
    UIImageView *_noteIcon;
    UILabel *_lyricLabel;
    NSString *_lastText;
}

+ (instancetype)shared {
    static IVLHomeBarLyricsManager *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [self new]; });
    return m;
}

- (void)start {
    if (_started) return;
    _started = YES;

    _stripView = [UIView new];
    _stripView.backgroundColor = [UIColor colorWithRed:0.129 green:0.129 blue:0.129 alpha:1.0];
    _stripView.clipsToBounds = YES;
    _stripView.hidden = YES;

    _topHairline = [UIView new];
    _topHairline.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    [_stripView addSubview:_topHairline];

    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:10.5 weight:UIImageSymbolWeightSemibold];
    _noteIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"music.note" withConfiguration:cfg]];
    _noteIcon.tintColor = [UIColor colorWithWhite:0.78 alpha:1.0];
    _noteIcon.contentMode = UIViewContentModeCenter;
    [_stripView addSubview:_noteIcon];

    _lyricLabel = [UILabel new];
    _lyricLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
    _lyricLabel.textColor = [UIColor colorWithWhite:0.94 alpha:1.0];
    _lyricLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_stripView addSubview:_lyricLabel];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openLyrics)];
    [_stripView addGestureRecognizer:tap];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(refresh) name:IVLSettingsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(refresh) name:IVLTrackDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(refresh) name:IVLLyricsDidChangeNotification object:nil];

    _timer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)dealloc {
    [_timer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)openLyrics {
    UIViewController *top = IVLTopViewController();
    if (!top) return;
    IVLLyricsViewController *vc = [IVLLyricsViewController new];
    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    [top presentViewController:vc animated:YES completion:nil];
}

#pragma mark - Mini player detection & color sampling

- (UIWindow *)mainAppWindow {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        for (UIWindow *w in ws.windows) {
            if (!w.hidden && w.windowLevel == UIWindowLevelNormal && w.bounds.size.width > 0) return w;
        }
    }
    return nil;
}

- (UIView *)findMiniBarInView:(UIView *)v window:(UIWindow *)win depth:(NSInteger)depth {
    if (!v || v == _stripView || v.hidden || v.alpha < 0.05 || depth > 14) return nil;
    NSString *cls = NSStringFromClass(v.class);
    BOOL nameMatch = [cls containsString:@"MiniBar"] || [cls containsString:@"PlayerBar"] || [cls containsString:@"MiniPlayer"];
    if (nameMatch) {
        CGRect f = [v convertRect:v.bounds toView:win];
        CGFloat winW = win.bounds.size.width;
        CGFloat winH = win.bounds.size.height;
        if (f.size.width >= winW * 0.90 && f.size.height >= 44.0 && f.size.height <= 96.0
            && f.origin.y > winH * 0.50 && CGRectGetMaxY(f) <= winH - 30.0) {
            return v;
        }
    }
    for (UIView *sub in v.subviews) {
        UIView *hit = [self findMiniBarInView:sub window:win depth:depth + 1];
        if (hit) return hit;
    }
    return nil;
}

- (UIColor *)sampleColorFromView:(UIView *)v depth:(NSInteger)depth {
    if (!v || depth > 4) return nil;
    UIColor *bg = v.backgroundColor;
    if (bg) {
        CGFloat a = 0;
        if ([bg getWhite:NULL alpha:&a] || [bg getRed:NULL green:NULL blue:NULL alpha:&a]) {
            if (a > 0.7) return bg;
        }
    }
    for (UIView *sub in v.subviews) {
        if (sub.bounds.size.width >= v.bounds.size.width * 0.85 && sub.bounds.size.height >= v.bounds.size.height * 0.7) {
            UIColor *c = [self sampleColorFromView:sub depth:depth + 1];
            if (c) return c;
        }
    }
    return nil;
}

- (void)detach {
    UIView *old = _attachedMiniBar;
    if (old) {
        old.layer.sublayerTransform = CATransform3DIdentity;
        old.clipsToBounds = _savedClipsToBounds;
    }
    _attachedMiniBar = nil;
    _stripView.hidden = YES;
    [_stripView removeFromSuperview];
}

#pragma mark - Live update

- (void)refresh { [self tick]; }

- (void)tick {
    BOOL enabled = [IVLSettings boolForKey:IVLKeyEnabled] && [IVLSettings boolForKey:IVLKeyHomeBarLyrics];
    IVLPlaybackManager *pm = [IVLPlaybackManager shared];
    if (!enabled || !pm.track) {
        [self detach];
        return;
    }

    UIWindow *win = [self mainAppWindow];
    if (!win) { [self detach]; return; }

    // Hide while a modal screen (lyrics, settings, sheets) is presented on top
    if (win.rootViewController.presentedViewController != nil) {
        _stripView.hidden = YES;
        return;
    }

    UIView *miniBar = _attachedMiniBar;
    CGRect fInWin = CGRectZero;
    if (miniBar) {
        if (miniBar.window != win || miniBar.hidden || miniBar.alpha < 0.1) {
            [self detach];
            miniBar = nil;
        } else {
            fInWin = [miniBar convertRect:miniBar.bounds toView:win];
            if (fInWin.origin.y < win.bounds.size.height * 0.50 || CGRectGetMaxY(fInWin) > win.bounds.size.height - 30.0) {
                [self detach];
                miniBar = nil;
            }
        }
    }
    if (!miniBar) {
        miniBar = [self findMiniBarInView:win window:win depth:0];
        if (miniBar) {
            _savedClipsToBounds = miniBar.clipsToBounds;
            _attachedMiniBar = miniBar;
            fInWin = [miniBar convertRect:miniBar.bounds toView:win];
        }
    }
    if (!miniBar) {
        [self detach];
        return;
    }

    // Use CALayer.sublayerTransform instead of UIView.transform so YouTube Music's own setFrame:
    // never breaks or pushes the mini bar off-screen.
    miniBar.clipsToBounds = NO;
    CATransform3D shift = CATransform3DMakeTranslation(0, -kIVLHomeBarHeight, 0);
    if (!CATransform3DEqualToTransform(miniBar.layer.sublayerTransform, shift)) {
        miniBar.layer.sublayerTransform = shift;
    }

    // Place the matching-color lyric strip directly in the main window at the bottom 26pt of miniBar's slot
    // (directly underneath the shifted artwork/controls and directly above the tab bar).
    if (_stripView.superview != win) {
        [win addSubview:_stripView];
    }
    CGRect targetFrame = CGRectMake(fInWin.origin.x, CGRectGetMaxY(fInWin) - kIVLHomeBarHeight, fInWin.size.width, kIVLHomeBarHeight);
    if (!CGRectEqualToRect(_stripView.frame, targetFrame)) {
        _stripView.frame = targetFrame;
        _topHairline.frame = CGRectMake(0, 0, targetFrame.size.width, 0.5);
        _noteIcon.frame = CGRectMake(14.0, 0, 16.0, kIVLHomeBarHeight);
        _lyricLabel.frame = CGRectMake(34.0, 0, targetFrame.size.width - 48.0, kIVLHomeBarHeight);
    }
    _stripView.hidden = NO;
    [win bringSubviewToFront:_stripView];

    UIColor *bg = [self sampleColorFromView:miniBar depth:0] ?: [UIColor colorWithRed:0.129 green:0.129 blue:0.129 alpha:1.0];
    _stripView.backgroundColor = bg;

    NSString *line = [pm currentLineText];
    NSString *display = line.length ? line : (pm.state == IVLLyricsStateLoading ? @"…" : @"♪");
    if (![display isEqualToString:_lastText]) {
        _lastText = [display copy];
        [UIView transitionWithView:_lyricLabel duration:0.16 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
            self->_lyricLabel.text = display;
        } completion:nil];
    }
}

@end
