#import "IVLExternalDisplay.h"
#import "IVLSettings.h"
#import "IVLPlaybackManager.h"
#import "IVLExtras.h"
#import "IVLLocalization.h"

@interface IVLExternalLyricsViewController : UIViewController
- (void)refreshTrack;
- (void)refreshLyrics;
- (void)tick;
@end

@implementation IVLExternalLyricsViewController {
    UIImageView *_bgView;
    UIVisualEffectView *_blurView;
    UIView *_dimView;

    UIImageView *_artView;
    UILabel *_titleLabel;
    UILabel *_artistLabel;
    UIView *_progTrack;
    UIView *_progFill;

    UILabel *_prevLabel;
    UILabel *_curLabel;
    UILabel *_subLabel;
    UILabel *_next1Label;
    UILabel *_next2Label;

    NSInteger _lastIdx;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    _lastIdx = NSNotFound;

    _bgView = [UIImageView new];
    _bgView.contentMode = UIViewContentModeScaleAspectFill;
    _bgView.clipsToBounds = YES;
    [self.view addSubview:_bgView];

    _blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    [self.view addSubview:_blurView];

    _dimView = [UIView new];
    _dimView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.42];
    [self.view addSubview:_dimView];

    _artView = [UIImageView new];
    _artView.contentMode = UIViewContentModeScaleAspectFill;
    _artView.clipsToBounds = YES;
    _artView.layer.cornerRadius = 18.0;
    _artView.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1.0];
    [self.view addSubview:_artView];

    _titleLabel = [UILabel new];
    _titleLabel.textColor = UIColor.whiteColor;
    _titleLabel.numberOfLines = 2;
    [self.view addSubview:_titleLabel];

    _artistLabel = [UILabel new];
    _artistLabel.textColor = [UIColor colorWithWhite:0.78 alpha:1.0];
    _artistLabel.numberOfLines = 1;
    [self.view addSubview:_artistLabel];

    _progTrack = [UIView new];
    _progTrack.backgroundColor = [UIColor colorWithWhite:1 alpha:0.22];
    _progTrack.layer.cornerRadius = 3.0;
    [self.view addSubview:_progTrack];

    _progFill = [UIView new];
    _progFill.backgroundColor = UIColor.whiteColor;
    _progFill.layer.cornerRadius = 3.0;
    [_progTrack addSubview:_progFill];

    _prevLabel = [UILabel new];
    _prevLabel.textColor = [UIColor colorWithWhite:1 alpha:0.32];
    _prevLabel.numberOfLines = 2;
    [self.view addSubview:_prevLabel];

    _curLabel = [UILabel new];
    _curLabel.textColor = UIColor.whiteColor;
    _curLabel.numberOfLines = 3;
    [self.view addSubview:_curLabel];

    _subLabel = [UILabel new];
    _subLabel.textColor = [UIColor colorWithWhite:0.82 alpha:0.88];
    _subLabel.numberOfLines = 2;
    [self.view addSubview:_subLabel];

    _next1Label = [UILabel new];
    _next1Label.textColor = [UIColor colorWithWhite:1 alpha:0.42];
    _next1Label.numberOfLines = 2;
    [self.view addSubview:_next1Label];

    _next2Label = [UILabel new];
    _next2Label.textColor = [UIColor colorWithWhite:1 alpha:0.22];
    _next2Label.numberOfLines = 2;
    [self.view addSubview:_next2Label];

    [self refreshTrack];
    [self refreshLyrics];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    CGFloat w = b.size.width, h = b.size.height;
    if (w <= 0 || h <= 0) return;

    _bgView.frame = b;
    _blurView.frame = b;
    _dimView.frame = b;

    CGFloat pad = floor(MIN(w, h) * 0.065);
    CGFloat leftW = floor(w * 0.34);
    CGFloat artSize = floor(MIN(leftW, h * 0.54));
    CGFloat artX = pad + floor((leftW - artSize) * 0.5);
    CGFloat artY = floor((h - artSize - 110.0) * 0.5);
    _artView.frame = CGRectMake(artX, MAX(pad, artY), artSize, artSize);

    CGFloat titleSize = MAX(18.0, floor(h * 0.036));
    CGFloat artistSize = MAX(14.0, floor(h * 0.025));
    _titleLabel.font = [UIFont systemFontOfSize:titleSize weight:UIFontWeightBold];
    _artistLabel.font = [UIFont systemFontOfSize:artistSize weight:UIFontWeightMedium];

    CGFloat infoY = CGRectGetMaxY(_artView.frame) + 20.0;
    _titleLabel.frame = CGRectMake(artX, infoY, artSize, titleSize * 2.4);
    _artistLabel.frame = CGRectMake(artX, CGRectGetMaxY(_titleLabel.frame) + 4.0, artSize, artistSize * 1.4);
    _progTrack.frame = CGRectMake(artX, CGRectGetMaxY(_artistLabel.frame) + 14.0, artSize, 6.0);

    CGFloat rightX = pad + leftW + pad * 0.8;
    CGFloat rightW = w - rightX - pad;

    CGFloat mainPt = MAX(26.0, floor(h * 0.056));
    CGFloat sidePt = MAX(18.0, floor(h * 0.036));
    CGFloat subPt = MAX(16.0, floor(h * 0.028));
    _prevLabel.font = [UIFont systemFontOfSize:sidePt weight:UIFontWeightSemibold];
    _curLabel.font = [UIFont systemFontOfSize:mainPt weight:UIFontWeightHeavy];
    _subLabel.font = [UIFont systemFontOfSize:subPt weight:UIFontWeightMedium];
    _next1Label.font = [UIFont systemFontOfSize:sidePt weight:UIFontWeightSemibold];
    _next2Label.font = [UIFont systemFontOfSize:sidePt weight:UIFontWeightMedium];

    CGFloat cy = h * 0.44;
    _prevLabel.frame = CGRectMake(rightX, cy - sidePt * 3.0 - 18.0, rightW, sidePt * 2.6);
    _curLabel.frame = CGRectMake(rightX, cy - mainPt * 0.4, rightW, mainPt * 3.3);
    _subLabel.frame = CGRectMake(rightX, CGRectGetMaxY(_curLabel.frame) + 6.0, rightW, subPt * 2.4);
    _next1Label.frame = CGRectMake(rightX, CGRectGetMaxY(_subLabel.frame) + 18.0, rightW, sidePt * 2.6);
    _next2Label.frame = CGRectMake(rightX, CGRectGetMaxY(_next1Label.frame) + 12.0, rightW, sidePt * 2.5);
}

- (void)refreshTrack {
    IVLTrack *t = [IVLPlaybackManager shared].track;
    _titleLabel.text = t.title.length ? t.title : IVLLoc(@"nothing_playing");
    _artistLabel.text = t.artist ?: @"";
    UIImage *img = [t.artworkImage isKindOfClass:[UIImage class]] ? (UIImage *)t.artworkImage : nil;
    _artView.image = img;
    _bgView.image = img;
    _curLabel.textColor = [IVLTheme accentColor];
}

- (void)refreshLyrics {
    _lastIdx = NSNotFound;
    [self tick];
}

- (void)tick {
    IVLPlaybackManager *pm = [IVLPlaybackManager shared];
    IVLTrack *t = pm.track;
    if (t.duration > 0) {
        double p = MAX(0.0, MIN(1.0, ([pm rawTimeMs] / 1000.0) / t.duration));
        _progFill.frame = CGRectMake(0, 0, _progTrack.bounds.size.width * p, _progTrack.bounds.size.height);
    } else {
        _progFill.frame = CGRectZero;
    }

    IVLLyrics *ly = pm.lyrics;
    if (!ly.lines.count) {
        _prevLabel.text = @"";
        _curLabel.text = (pm.state == IVLLyricsStateLoading) ? IVLLoc(@"loading") : @"♪";
        _subLabel.text = @"";
        _next1Label.text = @"";
        _next2Label.text = @"";
        return;
    }

    NSInteger nowMs = [pm currentTimeMs];
    NSInteger idx = 0;
    if (ly.synced) {
        idx = -1;
        for (NSInteger i = 0; i < (NSInteger)ly.lines.count; i++) {
            if (ly.lines[i].startMs <= nowMs) idx = i;
            else break;
        }
        if (idx < 0) idx = 0;
    }
    if (idx == _lastIdx) return;
    _lastIdx = idx;

    IVLLyricLine *cur = ly.lines[idx];
    NSString *prevTxt = (idx > 0) ? ly.lines[idx - 1].text : @"";
    NSString *curTxt = cur.instrumental ? @"• • •" : (cur.text ?: @"");
    NSString *subTxt = cur.translation.length ? cur.translation : (cur.pronunciation ?: @"");
    NSString *n1Txt = (idx + 1 < (NSInteger)ly.lines.count) ? ly.lines[idx + 1].text : @"";
    NSString *n2Txt = (idx + 2 < (NSInteger)ly.lines.count) ? ly.lines[idx + 2].text : @"";

    [UIView transitionWithView:self.view duration:0.22 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
        self->_prevLabel.text = prevTxt;
        self->_curLabel.text = curTxt;
        self->_subLabel.text = subTxt;
        self->_next1Label.text = n1Txt;
        self->_next2Label.text = n2Txt;
    } completion:nil];
}

@end

@implementation IVLExternalDisplayManager {
    BOOL _started;
    UIWindow *_extWindow;
    IVLExternalLyricsViewController *_vc;
    NSTimer *_timer;
}

+ (instancetype)shared {
    static IVLExternalDisplayManager *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [self new]; });
    return m;
}

- (void)start {
    if (_started) return;
    _started = YES;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(syncDisplay) name:UISceneWillConnectNotification object:nil];
    [nc addObserver:self selector:@selector(syncDisplay) name:UISceneDidDisconnectNotification object:nil];
    [nc addObserver:self selector:@selector(syncDisplay) name:UIScreenDidConnectNotification object:nil];
    [nc addObserver:self selector:@selector(syncDisplay) name:UIScreenDidDisconnectNotification object:nil];
    [nc addObserver:self selector:@selector(syncDisplay) name:IVLSettingsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(onTrack) name:IVLTrackDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(onTrack) name:IVLArtworkDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(onLyrics) name:IVLLyricsDidChangeNotification object:nil];
    [self syncDisplay];
}

- (void)onTrack { [_vc refreshTrack]; }
- (void)onLyrics { [_vc refreshLyrics]; }

- (void)teardown {
    [_timer invalidate];
    _timer = nil;
    _extWindow.hidden = YES;
    _extWindow = nil;
    _vc = nil;
}

- (void)syncDisplay {
    BOOL enabled = [IVLSettings boolForKey:IVLKeyEnabled] && [IVLSettings boolForKey:IVLKeyExternalDisplay];
    if (!enabled) { [self teardown]; return; }

    UIWindowScene *extScene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        if ([ws.session.role isEqualToString:UIWindowSceneSessionRoleExternalDisplayNonInteractive]
            || ws.screen != UIScreen.mainScreen) {
            extScene = ws;
            break;
        }
    }

    if (extScene) {
        if (_extWindow && _extWindow.windowScene == extScene) return;
        [self teardown];
        _vc = [IVLExternalLyricsViewController new];
        _extWindow = [[UIWindow alloc] initWithWindowScene:extScene];
        _extWindow.rootViewController = _vc;
        _extWindow.hidden = NO;
        [_extWindow makeKeyAndVisible];
    } else if (UIScreen.screens.count > 1) {
        UIScreen *sec = UIScreen.screens[1];
        if (_extWindow && _extWindow.screen == sec) return;
        [self teardown];
        _vc = [IVLExternalLyricsViewController new];
        _extWindow = [[UIWindow alloc] initWithFrame:sec.bounds];
        _extWindow.screen = sec;
        _extWindow.rootViewController = _vc;
        _extWindow.hidden = NO;
    } else {
        [self teardown];
        return;
    }

    _timer = [NSTimer scheduledTimerWithTimeInterval:0.15 target:_vc selector:@selector(tick) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
}

@end
