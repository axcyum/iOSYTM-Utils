#import "IVLExternalDisplay.h"
#import "IVLSettings.h"
#import "IVLPlaybackManager.h"
#import "IVLLyricCell.h"
#import "IVLExtras.h"
#import "IVLLocalization.h"
#import <AVKit/AVKit.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *IVLFormatSec(NSInteger totalSec) {
    if (totalSec < 0) totalSec = 0;
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(totalSec / 60), (long)(totalSec % 60)];
}

// Pre-bakes a small 220x220 blurred + darkened background once per track on a background queue,
// completely avoiding per-frame 1080p/4K CABackdropLayer (UIVisualEffectView) GPU stalls on HDMI.
static UIImage *IVLPreblurredStageBackground(UIImage *source) {
    if (!source) return nil;
    const CGFloat side = 220.0;
    CGRect rect = CGRectMake(0, 0, side, side);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1.0;
    fmt.opaque = YES;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:rect.size format:fmt];
    UIImage *scaled = [r imageWithActions:^(__unused UIGraphicsImageRendererContext *ctx) {
        CGFloat k = MAX(side / MAX(1.0, source.size.width), side / MAX(1.0, source.size.height));
        CGSize d = CGSizeMake(source.size.width * k, source.size.height * k);
        [source drawInRect:CGRectMake((side - d.width) * 0.5, (side - d.height) * 0.5, d.width, d.height)];
    }];
    UIImage *blurred = scaled;
    @try {
        static CIContext *ci;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ ci = [CIContext contextWithOptions:@{ kCIContextCacheIntermediates: @NO }]; });
        CIImage *inImg = [[CIImage alloc] initWithImage:scaled];
        CIFilter *f = [CIFilter filterWithName:@"CIGaussianBlur"];
        [f setValue:[inImg imageByClampingToExtent] forKey:kCIInputImageKey];
        [f setValue:@22.0 forKey:kCIInputRadiusKey];
        CGImageRef cg = [ci createCGImage:f.outputImage fromRect:rect];
        if (cg) { blurred = [UIImage imageWithCGImage:cg]; CGImageRelease(cg); }
    } @catch (__unused id e) {}

    return [r imageWithActions:^(__unused UIGraphicsImageRendererContext *ctx) {
        [blurred drawInRect:rect];
        [[UIColor colorWithWhite:0 alpha:0.46] setFill];
        UIRectFillUsingBlendMode(rect, kCGBlendModeNormal);
    }];
}

#pragma mark - 16:9 Apple TV-Style Lyrics Stage View Controller

@interface IVLExternalLyricsViewController : UIViewController
@property (nonatomic, assign) BOOL interactiveModal;
- (void)refreshTrack;
- (void)refreshLyrics;
- (void)tick;
@end

@implementation IVLExternalLyricsViewController {
    UIView *_stage;
    UIImageView *_bgView;

    UIView *_artShadow;
    UIImageView *_artView;
    UILabel *_titleLabel;
    UILabel *_artistLabel;
    UIView *_progTrack;
    UIView *_progFill;
    UILabel *_timeLeftLabel;
    UILabel *_timeRightLabel;

    UIView *_lyricsBox;
    UILabel *_prevLabel;
    IVLKaraokeLabel *_curLabel;
    UILabel *_subLabel;
    UILabel *_next1Label;
    UILabel *_next2Label;

    UIView *_hudBar;
    UIButton *_closeBtn;
    AVRoutePickerView *_routePicker;
    NSTimer *_modalTimer;
    NSUInteger _hudHideGen;

    UIImage *_lastSourceArt;
    UIColor *_cachedAccent;
    NSInteger _lastIdx;
    NSInteger _lastShownSec;
    NSInteger _lastShownDurSec;
    CGFloat _lastProgWidth;
    CGFloat _curFontPt;
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return _interactiveModal ? UIInterfaceOrientationMaskLandscape : UIInterfaceOrientationMaskAll;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    _lastIdx = NSNotFound;
    _lastShownSec = -1;
    _lastShownDurSec = -1;
    _lastProgWidth = -1.0;
    _curFontPt = 36.0;
    _cachedAccent = [IVLTheme accentColor] ?: UIColor.whiteColor;

    _stage = [UIView new];
    _stage.backgroundColor = UIColor.blackColor;
    _stage.clipsToBounds = YES;
    [self.view addSubview:_stage];

    _bgView = [UIImageView new];
    _bgView.contentMode = UIViewContentModeScaleAspectFill;
    _bgView.clipsToBounds = YES;
    _bgView.opaque = YES;
    _bgView.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];
    [_stage addSubview:_bgView];

    _artShadow = [UIView new];
    _artShadow.layer.shadowColor = UIColor.blackColor.CGColor;
    _artShadow.layer.shadowOpacity = 0.55;
    _artShadow.layer.shadowRadius = 24.0;
    _artShadow.layer.shadowOffset = CGSizeMake(0, 12);
    [_stage addSubview:_artShadow];

    _artView = [UIImageView new];
    _artView.contentMode = UIViewContentModeScaleAspectFill;
    _artView.clipsToBounds = YES;
    _artView.layer.cornerRadius = 18.0;
    _artView.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1.0];
    [_artShadow addSubview:_artView];

    _titleLabel = [UILabel new];
    _titleLabel.textColor = UIColor.whiteColor;
    _titleLabel.numberOfLines = 2;
    [_stage addSubview:_titleLabel];

    _artistLabel = [UILabel new];
    _artistLabel.textColor = [UIColor colorWithWhite:0.78 alpha:1.0];
    _artistLabel.numberOfLines = 1;
    [_stage addSubview:_artistLabel];

    _progTrack = [UIView new];
    _progTrack.backgroundColor = [UIColor colorWithWhite:1 alpha:0.22];
    _progTrack.layer.cornerRadius = 3.0;
    [_stage addSubview:_progTrack];

    _progFill = [UIView new];
    _progFill.backgroundColor = UIColor.whiteColor;
    _progFill.layer.cornerRadius = 3.0;
    [_progTrack addSubview:_progFill];

    _timeLeftLabel = [UILabel new];
    _timeLeftLabel.textColor = [UIColor colorWithWhite:1 alpha:0.55];
    [_stage addSubview:_timeLeftLabel];

    _timeRightLabel = [UILabel new];
    _timeRightLabel.textColor = [UIColor colorWithWhite:1 alpha:0.55];
    _timeRightLabel.textAlignment = NSTextAlignmentRight;
    [_stage addSubview:_timeRightLabel];

    _lyricsBox = [UIView new];
    _lyricsBox.backgroundColor = UIColor.clearColor;
    [_stage addSubview:_lyricsBox];

    _prevLabel = [UILabel new];
    _prevLabel.textColor = [UIColor colorWithWhite:1 alpha:0.30];
    _prevLabel.numberOfLines = 2;
    [_lyricsBox addSubview:_prevLabel];

    _curLabel = [IVLKaraokeLabel new];
    _curLabel.textColor = UIColor.whiteColor;
    _curLabel.brightColor = _cachedAccent;
    _curLabel.dimColor = [UIColor colorWithWhite:1 alpha:0.36];
    _curLabel.numberOfLines = 3;
    [_lyricsBox addSubview:_curLabel];

    _subLabel = [UILabel new];
    _subLabel.textColor = [UIColor colorWithWhite:0.86 alpha:0.90];
    _subLabel.numberOfLines = 2;
    [_lyricsBox addSubview:_subLabel];

    _next1Label = [UILabel new];
    _next1Label.textColor = [UIColor colorWithWhite:1 alpha:0.42];
    _next1Label.numberOfLines = 2;
    [_lyricsBox addSubview:_next1Label];

    _next2Label = [UILabel new];
    _next2Label.textColor = [UIColor colorWithWhite:1 alpha:0.22];
    _next2Label.numberOfLines = 2;
    [_lyricsBox addSubview:_next2Label];

    if (_interactiveModal) {
        UIApplication.sharedApplication.idleTimerDisabled = YES;

        _hudBar = [UIView new];
        _hudBar.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.78];
        _hudBar.layer.cornerRadius = 21.0;
        [_stage addSubview:_hudBar];

        _routePicker = [[AVRoutePickerView alloc] initWithFrame:CGRectMake(8, 3, 36, 36)];
        _routePicker.tintColor = UIColor.whiteColor;
        _routePicker.activeTintColor = _cachedAccent;
        _routePicker.prioritizesVideoDevices = YES;
        [_hudBar addSubview:_routePicker];

        _closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        [_closeBtn setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
        _closeBtn.tintColor = UIColor.whiteColor;
        _closeBtn.frame = CGRectMake(48, 3, 36, 36);
        [_closeBtn addTarget:self action:@selector(closeModal) forControlEvents:UIControlEventTouchUpInside];
        [_hudBar addSubview:_closeBtn];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(pokeHUD)];
        [_stage addGestureRecognizer:tap];
        [self scheduleHUDAutoHide];

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(refreshTrack) name:IVLTrackDidChangeNotification object:nil];
        [nc addObserver:self selector:@selector(refreshTrack) name:IVLArtworkDidChangeNotification object:nil];
        [nc addObserver:self selector:@selector(refreshLyrics) name:IVLLyricsDidChangeNotification object:nil];
        _modalTimer = [NSTimer timerWithTimeInterval:1.0 / 30.0 target:self selector:@selector(tick) userInfo:nil repeats:YES];
        _modalTimer.tolerance = 0.008;
        [[NSRunLoop mainRunLoop] addTimer:_modalTimer forMode:NSRunLoopCommonModes];
    }

    [self refreshTrack];
    [self refreshLyrics];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_interactiveModal) {
        if (@available(iOS 16.0, *)) {
            UIWindowScene *ws = self.view.window.windowScene;
            if (ws) {
                UIWindowSceneGeometryPreferencesIOS *pref = [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:UIInterfaceOrientationMaskLandscapeRight];
                [ws requestGeometryUpdateWithPreferences:pref errorHandler:^(__unused NSError *e) {}];
            }
        }
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (_interactiveModal) {
        [_modalTimer invalidate];
        _modalTimer = nil;
        UIApplication.sharedApplication.idleTimerDisabled = NO;
        if (@available(iOS 16.0, *)) {
            UIWindowScene *ws = self.view.window.windowScene;
            if (ws) {
                UIWindowSceneGeometryPreferencesIOS *pref = [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:UIInterfaceOrientationMaskPortrait];
                [ws requestGeometryUpdateWithPreferences:pref errorHandler:^(__unused NSError *e) {}];
            }
        }
    }
}

- (void)dealloc {
    [_modalTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)closeModal {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)pokeHUD {
    if (!_hudBar) return;
    [UIView animateWithDuration:0.2 animations:^{ self->_hudBar.alpha = 1.0; }];
    [self scheduleHUDAutoHide];
}

- (void)scheduleHUDAutoHide {
    NSUInteger gen = ++_hudHideGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen != self->_hudHideGen || !self->_hudBar) return;
        [UIView animateWithDuration:0.35 animations:^{ self->_hudBar.alpha = 0.0; }];
    });
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect outer = self.view.bounds;
    if (outer.size.width <= 0 || outer.size.height <= 0) return;

    BOOL forceRotate = (_interactiveModal && outer.size.width < outer.size.height);
    CGFloat w = forceRotate ? outer.size.height : outer.size.width;
    CGFloat h = forceRotate ? outer.size.width : outer.size.height;

    _stage.transform = CGAffineTransformIdentity;
    _stage.bounds = CGRectMake(0, 0, w, h);
    _stage.center = CGPointMake(outer.size.width * 0.5, outer.size.height * 0.5);
    if (forceRotate) {
        _stage.transform = CGAffineTransformMakeRotation(M_PI_2);
    }

    _bgView.frame = CGRectMake(0, 0, w, h);

    CGFloat pad = floor(MIN(w, h) * 0.065);
    CGFloat leftW = floor(w * 0.34);
    CGFloat artSize = floor(MIN(leftW, h * 0.52));
    CGFloat artX = pad + floor((leftW - artSize) * 0.5);
    CGFloat artY = floor((h - artSize - 115.0) * 0.5);
    _artShadow.frame = CGRectMake(artX, MAX(pad, artY), artSize, artSize);
    _artShadow.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_artShadow.bounds cornerRadius:18.0].CGPath;
    _artView.frame = _artShadow.bounds;

    CGFloat titleSize = MAX(17.0, floor(h * 0.035));
    CGFloat artistSize = MAX(13.0, floor(h * 0.024));
    CGFloat timeSize = MAX(11.0, floor(h * 0.020));
    _titleLabel.font = [UIFont systemFontOfSize:titleSize weight:UIFontWeightBold];
    _artistLabel.font = [UIFont systemFontOfSize:artistSize weight:UIFontWeightMedium];
    _timeLeftLabel.font = [UIFont monospacedDigitSystemFontOfSize:timeSize weight:UIFontWeightMedium];
    _timeRightLabel.font = [UIFont monospacedDigitSystemFontOfSize:timeSize weight:UIFontWeightMedium];

    CGFloat infoY = CGRectGetMaxY(_artShadow.frame) + 18.0;
    _titleLabel.frame = CGRectMake(artX, infoY, artSize, titleSize * 2.4);
    _artistLabel.frame = CGRectMake(artX, CGRectGetMaxY(_titleLabel.frame) + 3.0, artSize, artistSize * 1.4);
    _progTrack.frame = CGRectMake(artX, CGRectGetMaxY(_artistLabel.frame) + 12.0, artSize, 6.0);
    _timeLeftLabel.frame = CGRectMake(artX, CGRectGetMaxY(_progTrack.frame) + 6.0, artSize * 0.5, timeSize * 1.3);
    _timeRightLabel.frame = CGRectMake(artX + artSize * 0.5, CGRectGetMaxY(_progTrack.frame) + 6.0, artSize * 0.5, timeSize * 1.3);

    CGFloat rightX = pad + leftW + pad * 0.75;
    CGFloat rightW = MAX(120.0, w - rightX - pad);
    _lyricsBox.transform = CGAffineTransformIdentity;
    _lyricsBox.frame = CGRectMake(rightX, 0, rightW, h);

    CGFloat mainPt = MAX(24.0, floor(h * 0.055));
    CGFloat sidePt = MAX(16.0, floor(h * 0.035));
    CGFloat subPt = MAX(15.0, floor(h * 0.028));
    _curFontPt = mainPt;
    _prevLabel.font = [UIFont systemFontOfSize:sidePt weight:UIFontWeightSemibold];
    _curLabel.font = [UIFont systemFontOfSize:mainPt weight:UIFontWeightHeavy];
    _subLabel.font = [UIFont systemFontOfSize:subPt weight:UIFontWeightMedium];
    _next1Label.font = [UIFont systemFontOfSize:sidePt weight:UIFontWeightSemibold];
    _next2Label.font = [UIFont systemFontOfSize:sidePt weight:UIFontWeightMedium];

    CGFloat cy = h * 0.43;
    _prevLabel.frame = CGRectMake(0, cy - sidePt * 2.9 - 16.0, rightW, sidePt * 2.6);
    _curLabel.frame = CGRectMake(0, cy - mainPt * 0.4, rightW, mainPt * 3.3);
    _subLabel.frame = CGRectMake(0, CGRectGetMaxY(_curLabel.frame) + 6.0, rightW, subPt * 2.4);
    _next1Label.frame = CGRectMake(0, CGRectGetMaxY(_subLabel.frame) + 16.0, rightW, sidePt * 2.6);
    _next2Label.frame = CGRectMake(0, CGRectGetMaxY(_next1Label.frame) + 10.0, rightW, sidePt * 2.5);

    if (_hudBar) {
        _hudBar.frame = CGRectMake(w - pad - 92.0, MAX(18.0, pad * 0.65), 92.0, 42.0);
    }

    _lastIdx = NSNotFound;
    _lastProgWidth = -1.0;
    [self tick];
}

- (void)refreshTrack {
    IVLTrack *t = [IVLPlaybackManager shared].track;
    _titleLabel.text = t.title.length ? t.title : IVLLoc(@"nothing_playing");
    _artistLabel.text = t.artist ?: @"";
    _cachedAccent = [IVLTheme accentColor] ?: UIColor.whiteColor;
    _curLabel.textColor = _cachedAccent;
    _curLabel.brightColor = _cachedAccent;

    UIImage *img = [t.artworkImage isKindOfClass:[UIImage class]] ? (UIImage *)t.artworkImage : nil;
    _artView.image = img;
    if (img != _lastSourceArt) {
        _lastSourceArt = img;
        if (!img) {
            _bgView.image = nil;
        } else {
            __weak typeof(self) ws = self;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                UIImage *baked = IVLPreblurredStageBackground(img);
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(ws) ss = ws;
                    if (!ss || ss->_lastSourceArt != img) return;
                    ss->_bgView.image = baked;
                });
            });
        }
    }
}

- (void)refreshLyrics {
    _cachedAccent = [IVLTheme accentColor] ?: UIColor.whiteColor;
    _curLabel.textColor = _cachedAccent;
    _curLabel.brightColor = _cachedAccent;
    _lastIdx = NSNotFound;
    [self tick];
}

- (void)tick {
    IVLPlaybackManager *pm = [IVLPlaybackManager shared];
    IVLTrack *t = pm.track;
    NSInteger rawMs = [pm rawTimeMs];
    NSInteger rawSec = MAX(0, rawMs / 1000);
    if (rawSec != _lastShownSec) {
        _lastShownSec = rawSec;
        _timeLeftLabel.text = IVLFormatSec(rawSec);
    }
    if (t.duration > 0) {
        NSInteger durSec = (NSInteger)round(t.duration);
        if (durSec != _lastShownDurSec) {
            _lastShownDurSec = durSec;
            _timeRightLabel.text = IVLFormatSec(durSec);
        }
        double p = MAX(0.0, MIN(1.0, (rawMs / 1000.0) / t.duration));
        CGFloat newW = _progTrack.bounds.size.width * p;
        if (fabs(newW - _lastProgWidth) >= 0.5) {
            _lastProgWidth = newW;
            _progFill.frame = CGRectMake(0, 0, newW, _progTrack.bounds.size.height);
        }
    } else if (_lastShownDurSec != -2) {
        _lastShownDurSec = -2;
        _lastProgWidth = 0;
        _progFill.frame = CGRectZero;
        _timeRightLabel.text = @"--:--";
    }

    IVLLyrics *ly = pm.lyrics;
    if (!ly.lines.count) {
        if (_lastIdx != -10) {
            _lastIdx = -10;
            _curLabel.karaokeActive = NO;
            _curLabel.words = nil;
            _prevLabel.text = @"";
            _curLabel.text = (pm.state == IVLLyricsStateLoading) ? IVLLoc(@"loading") : @"♪";
            _subLabel.text = @"";
            _next1Label.text = @"";
            _next2Label.text = @"";
        }
        return;
    }

    NSInteger nowMs = [pm currentTimeMs];
    NSInteger idx = 0;
    if (ly.synced) {
        NSInteger found = [ly indexOfLineAtTime:nowMs];
        idx = (found >= 0) ? found : 0;
    }

    IVLLyricLine *cur = ly.lines[idx];
    BOOL useKaraoke = (cur.words.count > 0 && !cur.instrumental && [IVLSettings boolForKey:IVLKeyKaraoke]);

    if (idx != _lastIdx) {
        _lastIdx = idx;
        _prevLabel.text = (idx > 0) ? ly.lines[idx - 1].text : @"";
        NSString *curTxt = cur.instrumental ? @"• • •" : (cur.text ?: @"");
        if (useKaraoke) {
            UIFont *f = [UIFont systemFontOfSize:_curFontPt weight:UIFontWeightHeavy];
            _curLabel.attributedText = [[NSAttributedString alloc] initWithString:curTxt attributes:@{
                NSFontAttributeName: f,
                NSForegroundColorAttributeName: _cachedAccent,
            }];
            _curLabel.words = cur.words;
            _curLabel.karaokeActive = YES;
        } else {
            _curLabel.karaokeActive = NO;
            _curLabel.words = nil;
            _curLabel.attributedText = nil;
            _curLabel.text = curTxt;
        }
        _subLabel.text = cur.translation.length ? cur.translation : (cur.pronunciation ?: @"");
        _next1Label.text = (idx + 1 < (NSInteger)ly.lines.count) ? ly.lines[idx + 1].text : @"";
        _next2Label.text = (idx + 2 < (NSInteger)ly.lines.count) ? ly.lines[idx + 2].text : @"";

        // Pure GPU layer transform slide (zero offscreen snapshot rasterization!)
        _lyricsBox.transform = CGAffineTransformMakeTranslation(0, 12.0);
        _lyricsBox.alpha = 0.45;
        [UIView animateWithDuration:0.20 delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction animations:^{
            self->_lyricsBox.transform = CGAffineTransformIdentity;
            self->_lyricsBox.alpha = 1.0;
        } completion:nil];
    }

    if (useKaraoke) {
        _curLabel.timeMs = nowMs;
    }
}

@end

#pragma mark - External UIWindowScene Delegate (iOS 13–27+)

@interface IVLExternalDisplayManager ()
- (void)attachToWindowScene:(UIWindowScene *)ws;
- (void)detachWindowScene:(UIScene *)scene;
- (void)syncDisplay;
@end

@interface IVLExternalSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation IVLExternalSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    if (![scene isKindOfClass:[UIWindowScene class]]) return;
    [[IVLExternalDisplayManager shared] attachToWindowScene:(UIWindowScene *)scene];
}

- (void)sceneDidDisconnect:(UIScene *)scene {
    [[IVLExternalDisplayManager shared] detachWindowScene:scene];
}

@end

#pragma mark - Half-sheet Quick Controller (AirPlay Picker + Status + Fullscreen TV Stage)

@interface IVLExternalDisplaySheetViewController : UITableViewController
@end

@implementation IVLExternalDisplaySheetViewController {
    NSTimer *_statusTimer;
    AVRoutePickerView *_hiddenPicker;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = IVLLoc(@"external_display");
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];

    _hiddenPicker = [[AVRoutePickerView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
    _hiddenPicker.alpha = 0.01;
    _hiddenPicker.prioritizesVideoDevices = YES;
    [self.view addSubview:_hiddenPicker];

    _statusTimer = [NSTimer scheduledTimerWithTimeInterval:0.8 target:self selector:@selector(refreshStatus) userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_statusTimer invalidate];
    _statusTimer = nil;
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)refreshStatus {
    UITableViewCell *c = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:1]];
    if (c) c.detailTextLabel.text = [IVLExternalDisplayManager statusText];
}

- (void)triggerAirPlayPicker {
    for (UIView *sub in _hiddenPicker.subviews) {
        if ([sub isKindOfClass:[UIButton class]]) {
            [(UIButton *)sub sendActionsForControlEvents:UIControlEventTouchUpInside];
            return;
        }
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 0 ? 3 : 1; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == 0 ? IVLLoc(@"footer_external_display") : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 1) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        c.textLabel.text = IVLLoc(@"status");
        c.detailTextLabel.text = [IVLExternalDisplayManager statusText];
        return c;
    }
    if (indexPath.row == 0) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        c.textLabel.text = IVLLoc(@"external_display");
        UISwitch *sw = [UISwitch new];
        sw.on = [IVLSettings boolForKey:IVLKeyExternalDisplay];
        [sw addAction:[UIAction actionWithHandler:^(UIAction *a) {
            [IVLSettings setBool:((UISwitch *)a.sender).on forKey:IVLKeyExternalDisplay];
        }] forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
        return c;
    }
    if (indexPath.row == 1) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.imageView.image = [UIImage systemImageNamed:@"airplayvideo"];
        c.imageView.tintColor = [IVLTheme accentColor];
        c.textLabel.text = IVLLoc(@"ext_airplay_picker");
        AVRoutePickerView *rv = [[AVRoutePickerView alloc] initWithFrame:CGRectMake(0, 0, 32, 32)];
        rv.tintColor = UIColor.secondaryLabelColor;
        rv.activeTintColor = [IVLTheme accentColor];
        rv.prioritizesVideoDevices = YES;
        c.accessoryView = rv;
        return c;
    }
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    c.imageView.image = [UIImage systemImageNamed:@"tv.fill"];
    c.imageView.tintColor = [IVLTheme accentColor];
    c.textLabel.text = IVLLoc(@"ext_stage_open");
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 0) return;
    if (indexPath.row == 1) {
        [self triggerAirPlayPicker];
    } else if (indexPath.row == 2) {
        UIViewController *presenter = self.presentingViewController;
        [self dismissViewControllerAnimated:YES completion:^{
            if (presenter) [IVLExternalDisplayManager presentFullscreenStageFrom:presenter];
        }];
    }
}

@end

#pragma mark - External Display Manager

static BOOL IVLIsExternalSceneRole(NSString *role) {
    if (!role.length) return NO;
    if (@available(iOS 16.0, *)) {
        if ([role isEqualToString:UIWindowSceneSessionRoleExternalDisplayNonInteractive]) return YES;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if ([role isEqualToString:UIWindowSceneSessionRoleExternalDisplay]) return YES;
#pragma clang diagnostic pop
    return [role containsString:@"ExternalDisplay"];
}

@implementation IVLExternalDisplayManager {
    BOOL _started;
    BOOL _hookedAppDelegate;
    UIWindow *_extWindow;
    UIWindowScene *_extScene;
    UIScreen *_extScreen;
    IVLExternalLyricsViewController *_vc;
    NSTimer *_tickTimer;
    NSTimer *_watchTimer;
    id _sceneAccessoryRegistration;
    NSString *_modeLabel;
}

+ (instancetype)shared {
    static IVLExternalDisplayManager *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [self new]; });
    return m;
}

+ (BOOL)isConnected {
    IVLExternalDisplayManager *m = [self shared];
    if (m->_extWindow && !m->_extWindow.hidden) return YES;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)s;
            if (IVLIsExternalSceneRole(ws.session.role) || ws.screen != UIScreen.mainScreen) return YES;
        }
    }
    return UIScreen.screens.count > 1;
}

+ (NSString *)statusText {
    if (![IVLSettings boolForKey:IVLKeyExternalDisplay]) return IVLLoc(@"off");
    IVLExternalDisplayManager *m = [self shared];
    if (m->_extWindow && !m->_extWindow.hidden) {
        CGSize sz = m->_extWindow.bounds.size;
        return [NSString stringWithFormat:IVLLoc(@"ext_connected_fmt"), sz.width, sz.height, m->_modeLabel ?: @"TV"];
    }
    return IVLLoc(@"ext_waiting");
}

+ (void)presentQuickSheetFrom:(UIViewController *)vc {
    if (!vc) return;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[IVLExternalDisplaySheetViewController new]];
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sh = nav.sheetPresentationController;
        sh.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
        sh.prefersGrabberVisible = YES;
    }
    [vc presentViewController:nav animated:YES completion:nil];
}

+ (void)presentFullscreenStageFrom:(UIViewController *)vc {
    if (!vc) return;
    IVLExternalLyricsViewController *stage = [IVLExternalLyricsViewController new];
    stage.interactiveModal = YES;
    stage.modalPresentationStyle = UIModalPresentationFullScreen;
    stage.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [vc presentViewController:stage animated:YES completion:nil];
}

- (void)installAppDelegateSceneHookIfSceneBased {
    if (_hookedAppDelegate) return;
    id appDel = UIApplication.sharedApplication.delegate;
    if (!appDel) return;
    Class cls = [appDel class];
    SEL sel = @selector(application:configurationForConnectingSceneSession:options:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return; // App uses legacy AppDelegate window lifecycle; do NOT add scene lifecycle method!
    _hookedAppDelegate = YES;

    typedef UISceneConfiguration *(*IVLSceneCfgFn)(id, SEL, UIApplication *, UISceneSession *, UISceneConnectionOptions *);
    IVLSceneCfgFn orig = (IVLSceneCfgFn)method_getImplementation(m);
    IMP rep = imp_implementationWithBlock(^UISceneConfiguration *(id selfDel, UIApplication *app, UISceneSession *session, UISceneConnectionOptions *opts) {
        if (IVLIsExternalSceneRole(session.role)) {
            UISceneConfiguration *cfg = [[UISceneConfiguration alloc] initWithName:@"IVLExternalDisplay" sessionRole:session.role];
            cfg.delegateClass = [IVLExternalSceneDelegate class];
            return cfg;
        }
        return orig(selfDel, sel, app, session, opts);
    });
    method_setImplementation(m, rep);
}

// Dynamic iOS 27+ UISceneAccessory registration (no-op on iOS <= 26)
- (void)ensureSceneAccessoryIfAvailable {
    if (_sceneAccessoryRegistration) return;
    Class accCls = NSClassFromString(@"UISceneAccessory");
    SEL makeSel = NSSelectorFromString(@"externalNonInteractiveSceneAccessoryWithConfiguration:");
    SEL regSel = NSSelectorFromString(@"registerSceneAccessory:");
    if (!accCls || ![accCls respondsToSelector:makeSel]) return;

    UIViewController *rootVC = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] && !IVLIsExternalSceneRole(s.session.role)) {
            rootVC = ((UIWindowScene *)s).windows.firstObject.rootViewController;
            if (rootVC) break;
        }
    }
    if (!rootVC) rootVC = UIApplication.sharedApplication.delegate.window.rootViewController;
    if (!rootVC || ![rootVC respondsToSelector:regSel]) return;

    if (@available(iOS 16.0, *)) {
        UISceneConfiguration *cfg = [[UISceneConfiguration alloc] initWithName:nil sessionRole:UIWindowSceneSessionRoleExternalDisplayNonInteractive];
        cfg.delegateClass = [IVLExternalSceneDelegate class];
        id accessory = ((id (*)(id, SEL, id))objc_msgSend)(accCls, makeSel, cfg);
        if (accessory) {
            _sceneAccessoryRegistration = ((id (*)(id, SEL, id))objc_msgSend)(rootVC, regSel, accessory);
        }
    }
}

- (void)start {
    if (_started) return;
    _started = YES;
    [self installAppDelegateSceneHookIfSceneBased];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(syncDisplay) name:UISceneWillConnectNotification object:nil];
    [nc addObserver:self selector:@selector(syncDisplay) name:UISceneDidActivateNotification object:nil];
    [nc addObserver:self selector:@selector(syncDisplay) name:UISceneDidDisconnectNotification object:nil];
    [nc addObserver:self selector:@selector(syncDisplay) name:UIScreenDidConnectNotification object:nil];
    [nc addObserver:self selector:@selector(syncDisplay) name:UIScreenDidDisconnectNotification object:nil];
    [nc addObserver:self selector:@selector(syncDisplay) name:UIScreenModeDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(syncDisplay) name:IVLSettingsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(onTrack) name:IVLTrackDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(onTrack) name:IVLArtworkDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(onLyrics) name:IVLLyricsDidChangeNotification object:nil];
    [self syncDisplay];
}

- (void)onTrack { [_vc refreshTrack]; }
- (void)onLyrics { [_vc refreshLyrics]; }

- (void)teardownWindowOnly {
    [_tickTimer invalidate];
    _tickTimer = nil;
    if (_extWindow) {
        _extWindow.hidden = YES;
        _extWindow.rootViewController = nil;
        _extWindow = nil;
    }
    _extScene = nil;
    _extScreen = nil;
    _vc = nil;
    _modeLabel = nil;
}

- (void)teardownAll {
    [self teardownWindowOnly];
    [_watchTimer invalidate];
    _watchTimer = nil;
    _sceneAccessoryRegistration = nil;
}

- (void)startTickTimer {
    [_tickTimer invalidate];
    _tickTimer = [NSTimer timerWithTimeInterval:1.0 / 30.0 target:_vc selector:@selector(tick) userInfo:nil repeats:YES];
    _tickTimer.tolerance = 0.008;
    [[NSRunLoop mainRunLoop] addTimer:_tickTimer forMode:NSRunLoopCommonModes];
}

- (void)attachToWindowScene:(UIWindowScene *)ws {
    if (!ws) return;
    BOOL enabled = [IVLSettings boolForKey:IVLKeyEnabled] && [IVLSettings boolForKey:IVLKeyExternalDisplay];
    if (!enabled) return;
    if (_extWindow && _extScene == ws) return;

    [self teardownWindowOnly];
    UIScreen *sc = ws.screen;
    if (sc && sc.overscanCompensation != UIScreenOverscanCompensationNone) {
        sc.overscanCompensation = UIScreenOverscanCompensationNone;
    }
    _extScene = ws;
    _extScreen = sc;
    _modeLabel = @"Scene";
    _vc = [IVLExternalLyricsViewController new];
    _extWindow = [[UIWindow alloc] initWithWindowScene:ws];
    if (sc) _extWindow.frame = sc.bounds;
    _extWindow.windowLevel = UIWindowLevelNormal + 5;
    _extWindow.rootViewController = _vc;
    _extWindow.hidden = NO;
    _vc.view.frame = _extWindow.bounds;
    [self startTickTimer];
}

- (void)detachWindowScene:(UIScene *)scene {
    if (_extScene && scene == _extScene) {
        [self teardownWindowOnly];
    }
}

- (void)syncDisplay {
    BOOL enabled = [IVLSettings boolForKey:IVLKeyEnabled] && [IVLSettings boolForKey:IVLKeyExternalDisplay];
    if (!enabled) {
        [self teardownAll];
        return;
    }

    [self installAppDelegateSceneHookIfSceneBased];
    [self ensureSceneAccessoryIfAvailable];

    if (!_watchTimer) {
        _watchTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 target:self selector:@selector(pollScreens) userInfo:nil repeats:YES];
    }

    [self pollScreens];
}

- (void)pollScreens {
    BOOL enabled = [IVLSettings boolForKey:IVLKeyEnabled] && [IVLSettings boolForKey:IVLKeyExternalDisplay];
    if (!enabled) { [self teardownAll]; return; }

    // 1. Prefer an external UIWindowScene if connected
    UIWindowScene *foundScene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        if (IVLIsExternalSceneRole(ws.session.role) || (ws.screen && ws.screen != UIScreen.mainScreen)) {
            foundScene = ws;
            break;
        }
    }
    if (foundScene) {
        [self attachToWindowScene:foundScene];
        return;
    }

    // 2. Legacy non-scene UIScreen path (YTMAppDelegate without UIApplicationSceneManifest)
    UIScreen *foundScreen = nil;
    for (UIScreen *sc in UIScreen.screens) {
        if (sc != UIScreen.mainScreen) {
            foundScreen = sc;
            break;
        }
    }
    if (foundScreen) {
        if (_extWindow && _extScreen == foundScreen && !_extWindow.hidden) return;
        [self teardownWindowOnly];

        if (foundScreen.overscanCompensation != UIScreenOverscanCompensationNone) {
            foundScreen.overscanCompensation = UIScreenOverscanCompensationNone;
        }
        if (foundScreen.currentMode.size.width == 0 && foundScreen.preferredMode) {
            foundScreen.currentMode = foundScreen.preferredMode;
        }

        _extScreen = foundScreen;
        _modeLabel = @"HDMI/AirPlay";
        _vc = [IVLExternalLyricsViewController new];

        UIWindow *w = [[UIWindow alloc] initWithFrame:foundScreen.bounds];
        // Detach from the phone's default main UIWindowScene first so .screen binds to the external display!
        if (w.windowScene && w.windowScene.screen != foundScreen) {
            w.windowScene = nil;
        }
        w.screen = foundScreen;
        w.frame = foundScreen.bounds;
        w.windowLevel = UIWindowLevelNormal + 10;
        w.rootViewController = _vc;
        _extWindow = w;
        w.hidden = NO;
        _vc.view.frame = w.bounds;
        [self startTickTimer];
        return;
    }

    // Disconnected
    if (_extWindow) {
        [self teardownWindowOnly];
    }
}

@end
