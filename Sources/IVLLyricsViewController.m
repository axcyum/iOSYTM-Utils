#import "IVLLyricsViewController.h"
#import "IVLLyricCell.h"
#import "IVLPlaybackManager.h"
#import "IVLSettings.h"
#import "IVLLocalization.h"
#import "IVLSearchViewController.h"
#import "IVLExtras.h"
#import "IVLPlayerPanel.h"
#import "IVLRecognizer.h"
#import "IVLProviderPickerViewController.h"
#import "IVLSettingsViewController.h"
#import "IVLRemoteControl.h"

#pragma mark - Helpers

void IVLLoadImage(NSString *url, void (^completion)(UIImage *)) {
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 20; });
    if (!url.length) { completion(nil); return; }
    UIImage *hit = [cache objectForKey:url];
    if (hit) { completion(hit); return; }
    NSURL *u = [NSURL URLWithString:url];
    if (!u) { completion(nil); return; }
    [[[NSURLSession sharedSession] dataTaskWithURL:u completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        UIImage *img = data ? [UIImage imageWithData:data] : nil;
        if (img) [cache setObject:img forKey:url];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(img); });
    }] resume];
}

UIViewController *IVLTopViewController(void) {
    UIWindow *key = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) { key = w; break; }
        if (key) break;
    }
    UIViewController *vc = key.rootViewController;
    while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) vc = vc.presentedViewController;
    return vc;
}

void IVLPresentSettings(UIViewController *presenter) {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[IVLSettingsViewController new]];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    nav.view.tintColor = [UIColor colorWithRed:1.0 green:0.176 blue:0.333 alpha:1.0];
    [(presenter ?: IVLTopViewController()) presentViewController:nav animated:YES completion:nil];
}

static UIButton *IVLToolButton(NSString *symbol, NSString *title) {
    UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
    cfg.image = [UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold]];
    cfg.imagePlacement = NSDirectionalRectEdgeTop;
    cfg.imagePadding = 5;
    cfg.baseForegroundColor = [UIColor colorWithWhite:1 alpha:0.75];
    NSAttributedString *t = [[NSAttributedString alloc] initWithString:title attributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold] }];
    cfg.attributedTitle = [[NSAttributedString alloc] initWithAttributedString:t];
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(8, 4, 8, 4);
    UIButton *b = [UIButton buttonWithConfiguration:cfg primaryAction:nil];
    b.accessibilityLabel = title;
    return b;
}

static void IVLSetToolOn(UIButton *b, BOOL on) {
    UIButtonConfiguration *cfg = b.configuration;
    cfg.baseForegroundColor = on ? UIColor.whiteColor : [UIColor colorWithWhite:1 alpha:0.6];
    UIBackgroundConfiguration *bg = [UIBackgroundConfiguration clearConfiguration];
    bg.backgroundColor = on ? [UIColor colorWithWhite:1 alpha:0.16] : UIColor.clearColor;
    bg.cornerRadius = 12;
    cfg.background = bg;
    b.configuration = cfg;
    b.accessibilityTraits = on ? (UIAccessibilityTraitButton | UIAccessibilityTraitSelected) : UIAccessibilityTraitButton;
}

#pragma mark - Controller

@interface IVLLyricsViewController () <UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate>
@end

@implementation IVLLyricsViewController {
    UIImageView *_bgImage;
    UIVisualEffectView *_blur;
    UIView *_dim;

    UIView *_header;
    UIImageView *_artwork;
    UILabel *_titleLabel;
    UILabel *_artistLabel;
    UIButton *_playButton;
    UIButton *_moreButton;
    UIButton *_closeButton;
    BOOL _shownHeaderPlaying;

    UITableView *_table;
    CAGradientLayer *_fadeMask;
    UIView *_tableHost;

    UIStackView *_stateView;
    UIImageView *_stateIcon;
    UILabel *_stateLabel;
    UIActivityIndicatorView *_spinner;
    UIButton *_retryButton;
    UIButton *_searchButton;

    UIButton *_followPill;
    UIStackView *_offsetPanel;
    UILabel *_offsetLabel;

    UIStackView *_toolbar;
    UIButton *_trButton, *_pronButton, *_sizeButton, *_syncButton, *_settingsButton;
    UILabel *_toast;

    NSArray<IVLLyricLine *> *_lines;
    BOOL _synced;
    IVLCellStyle _style;
    NSInteger _activeIndex;
    BOOL _following;
    NSTimer *_resumeTimer;
    CADisplayLink *_link;
    BOOL _prevIdleDisabled;
    CGFloat _pinchBase;
    CAGradientLayer *_gradient;
    IVLPlayerPanel *_panel;
    BOOL _showPlayer;
    __weak IVLLyrics *_shownLyrics;
}

+ (void)presentFromViewController:(UIViewController *)presenter {
    UIViewController *p = IVLTopViewController() ?: presenter;
    if ([p isKindOfClass:self] || [p.presentedViewController isKindOfClass:self]) return;
    IVLLyricsViewController *vc = [self new];
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.modalTransitionStyle = UIModalTransitionStyleCoverVertical;
    [p presentViewController:vc animated:YES completion:nil];
}

- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = UIColor.blackColor;
    _activeIndex = -1;
    _following = YES;

    [self buildBackground];
    [self buildHeader];
    [self buildToolbar];
    [self buildTable];
    [self buildStateView];
    [self buildOverlays];
    [self buildPlayerPanel];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(trackChanged) name:IVLTrackDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(lyricsChanged) name:IVLLyricsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(settingsChanged:) name:IVLSettingsDidChangeNotification object:nil];

    [[IVLPlaybackManager shared] refreshNow];
    [self trackChanged];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_link invalidate];
    [_resumeTimer invalidate];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if ([IVLSettings boolForKey:IVLKeyKeepAwake]) {
        _prevIdleDisabled = UIApplication.sharedApplication.idleTimerDisabled;
        UIApplication.sharedApplication.idleTimerDisabled = YES;
    }
    if (!_link) {
        _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
        if (@available(iOS 15.0, *)) _link.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
        [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if ([IVLSettings boolForKey:IVLKeyKeepAwake]) UIApplication.sharedApplication.idleTimerDisabled = _prevIdleDisabled;
    [_link invalidate];
    _link = nil;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _gradient.frame = _dim.bounds;
    _fadeMask.frame = _tableHost.bounds;
    CGFloat h = MAX(1, _tableHost.bounds.size.height);
    CGFloat edge = MIN(0.12, 48.0 / h);
    _fadeMask.locations = @[@0, @(edge), @(1 - edge), @1];
    [self applyInsets];
}

- (void)applyInsets {
    CGFloat h = MAX(1, _tableHost.bounds.size.height);
    // synced: room so the first/last line can sit at the reading position
    UIEdgeInsets inset = _synced ? UIEdgeInsetsMake(h * 0.3, 0, h * 0.55, 0) : UIEdgeInsetsMake(24, 0, 96, 0);
    if (!UIEdgeInsetsEqualToEdgeInsets(_table.contentInset, inset)) _table.contentInset = inset;
}

#pragma mark Build

- (void)buildBackground {
    _bgImage = [UIImageView new];
    _bgImage.contentMode = UIViewContentModeScaleAspectFill;
    _bgImage.clipsToBounds = YES;
    _bgImage.transform = CGAffineTransformMakeScale(1.4, 1.4);
    _blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
    _dim = [UIView new];
    _dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.25];
    for (UIView *v in @[_bgImage, _blur, _dim]) {
        v.frame = self.view.bounds;
        v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.view addSubview:v];
    }
    [self applyBackgroundStyle];
}

/// Themes (SimpMusic-style): 0 artwork blur, 1 solid colour, 2 artwork colour gradient, 3 AMOLED black
- (void)applyBackgroundStyle {
    NSInteger style = [IVLTheme style];
    BOOL blur = style == 0;
    _bgImage.hidden = !blur;
    _blur.hidden = !blur;
    [_gradient removeFromSuperlayer];
    _gradient = nil;
    if (style == 1) _dim.backgroundColor = [IVLTheme customBackgroundColor];
    else if (style == 3) _dim.backgroundColor = UIColor.blackColor;
    else if (style == 2) {
        _dim.backgroundColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.1 alpha:1];
        _gradient = [CAGradientLayer layer];
        _gradient.frame = _dim.bounds;
        _gradient.colors = @[(id)[UIColor colorWithRed:0.2 green:0.2 blue:0.25 alpha:1].CGColor, (id)UIColor.blackColor.CGColor];
        [_dim.layer addSublayer:_gradient];
        UIImage *art = _artwork.image;
        if (art) {
            __weak typeof(self) ws = self;
            [IVLTheme dominantColorsOfImage:art completion:^(UIColor *top, UIColor *bottom) {
                typeof(self) ss = ws;
                if (!ss || !ss->_gradient) return;
                [CATransaction begin];
                [CATransaction setAnimationDuration:0.5];
                ss->_gradient.colors = @[(id)top.CGColor, (id)bottom.CGColor];
                [CATransaction commit];
            }];
        }
    } else _dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.25];
}

- (void)buildHeader {
    _header = [UIView new];
    _header.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_header];

    UIView *grabber = [UIView new];
    grabber.backgroundColor = [UIColor colorWithWhite:1 alpha:0.35];
    grabber.layer.cornerRadius = 2.5;
    grabber.translatesAutoresizingMaskIntoConstraints = NO;
    [_header addSubview:grabber];

    _artwork = [UIImageView new];
    _artwork.contentMode = UIViewContentModeScaleAspectFill;
    _artwork.clipsToBounds = YES;
    _artwork.layer.cornerRadius = 8;
    _artwork.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
    _artwork.translatesAutoresizingMaskIntoConstraints = NO;

    _titleLabel = [UILabel new];
    _titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    _titleLabel.textColor = UIColor.whiteColor;
    _artistLabel = [UILabel new];
    _artistLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _artistLabel.textColor = [UIColor colorWithWhite:1 alpha:0.65];
    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _artistLabel]];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 2;

    UIImageSymbolConfiguration *sc = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightBold];
    _shownHeaderPlaying = [IVLRemoteControl isPlaying];
    _playButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_playButton setImage:[UIImage systemImageNamed:(_shownHeaderPlaying ? @"pause.fill" : @"play.fill") withConfiguration:sc] forState:UIControlStateNormal];
    [_playButton addTarget:self action:@selector(headerPlayTapped) forControlEvents:UIControlEventTouchUpInside];

    _moreButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_moreButton setImage:[UIImage systemImageNamed:@"ellipsis" withConfiguration:sc] forState:UIControlStateNormal];
    _moreButton.showsMenuAsPrimaryAction = YES;
    _moreButton.accessibilityLabel = IVLLoc(@"more");
    _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_closeButton setImage:[UIImage systemImageNamed:@"chevron.down" withConfiguration:sc] forState:UIControlStateNormal];
    _closeButton.accessibilityLabel = IVLLoc(@"close");
    [_closeButton addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    for (UIButton *b in @[_playButton, _moreButton, _closeButton]) {
        b.tintColor = UIColor.whiteColor;
        b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.13];
        b.layer.cornerRadius = 19;
        [b.widthAnchor constraintEqualToConstant:38].active = YES;
        [b.heightAnchor constraintEqualToConstant:38].active = YES;
    }

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[_artwork, texts, _playButton, _moreButton, _closeButton]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 10;
    [row setCustomSpacing:6 afterView:_playButton];
    [row setCustomSpacing:6 afterView:_moreButton];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [_header addSubview:row];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_header.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [_header.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_header.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [grabber.topAnchor constraintEqualToAnchor:_header.topAnchor constant:6],
        [grabber.centerXAnchor constraintEqualToAnchor:_header.centerXAnchor],
        [grabber.widthAnchor constraintEqualToConstant:36],
        [grabber.heightAnchor constraintEqualToConstant:5],
        [row.topAnchor constraintEqualToAnchor:grabber.bottomAnchor constant:10],
        [row.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [row.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [row.bottomAnchor constraintEqualToAnchor:_header.bottomAnchor constant:-8],
        [_artwork.widthAnchor constraintEqualToConstant:48],
        [_artwork.heightAnchor constraintEqualToConstant:48],
    ]];

    // Swipe down on the header to close
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dismissPan:)];
    [_header addGestureRecognizer:pan];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(followNow)];
    [texts addGestureRecognizer:tap];
    _artwork.userInteractionEnabled = YES;
    [_artwork addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleShowPlayer)]];
}

- (void)buildToolbar {
    _trButton = IVLToolButton(@"character.bubble", IVLLoc(@"translation"));
    [_trButton addTarget:self action:@selector(toggleTranslation) forControlEvents:UIControlEventTouchUpInside];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(translationLongPress:)];
    [_trButton addGestureRecognizer:lp];

    _pronButton = IVLToolButton(@"textformat.abc", IVLLoc(@"pronunciation"));
    _pronButton.showsMenuAsPrimaryAction = YES;

    _sizeButton = IVLToolButton(@"textformat.size", IVLLoc(@"text_size"));
    _sizeButton.showsMenuAsPrimaryAction = YES;

    _syncButton = IVLToolButton(@"timer", IVLLoc(@"sync"));
    [_syncButton addTarget:self action:@selector(toggleOffsetPanel) forControlEvents:UIControlEventTouchUpInside];

    _settingsButton = IVLToolButton(@"gearshape", IVLLoc(@"settings"));
    [_settingsButton addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];

    _toolbar = [[UIStackView alloc] initWithArrangedSubviews:@[_trButton, _pronButton, _sizeButton, _syncButton, _settingsButton]];
    _toolbar.axis = UILayoutConstraintAxisHorizontal;
    _toolbar.distribution = UIStackViewDistributionFillEqually;
    _toolbar.spacing = 6;
    _toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_toolbar];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_toolbar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [_toolbar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [_toolbar.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-6],
        [_toolbar.heightAnchor constraintGreaterThanOrEqualToConstant:58],
    ]];
    [self refreshToolbar];
}

- (void)buildTable {
    _tableHost = [UIView new];
    _tableHost.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view insertSubview:_tableHost belowSubview:_header];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _table.backgroundColor = UIColor.clearColor;
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.showsVerticalScrollIndicator = NO;
    _table.estimatedRowHeight = 60;
    _table.rowHeight = UITableViewAutomaticDimension;
    _table.dataSource = self;
    _table.delegate = self;
    _table.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [_table registerClass:[IVLLyricCell class] forCellReuseIdentifier:[IVLLyricCell reuseID]];
    _table.frame = _tableHost.bounds;
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_tableHost addSubview:_table];

    _fadeMask = [CAGradientLayer layer];
    _fadeMask.colors = @[(id)UIColor.clearColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor];
    _tableHost.layer.mask = _fadeMask;

    [NSLayoutConstraint activateConstraints:@[
        [_tableHost.topAnchor constraintEqualToAnchor:_header.bottomAnchor],
        [_tableHost.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableHost.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tableHost.bottomAnchor constraintEqualToAnchor:_toolbar.topAnchor constant:-4],
    ]];

    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinch:)];
    [_table addGestureRecognizer:pinch];
}

- (void)buildPlayerPanel {
    _panel = [IVLPlayerPanel new];
    _panel.translatesAutoresizingMaskIntoConstraints = NO;
    _panel.alpha = 0;
    _panel.hidden = YES;
    __weak typeof(self) ws = self;
    _panel.onShowLyrics = ^{ [ws setShowPlayer:NO animated:YES]; };
    _panel.onClose = ^{ [ws dismissViewControllerAnimated:NO completion:nil]; };
    _panel.onOpenProviderPicker = ^{ [ws openProviderPicker]; };
    _panel.onLyricsModeChanged = ^{ [ws refreshMoreMenu]; };
    // the queue lives in YouTube Music's own player: hand the screen back to it
    _panel.onQueue = ^{ [ws close]; };
    // a full-screen sheet of its own, above the lyrics header and toolbar
    [self.view addSubview:_panel];
    [NSLayoutConstraint activateConstraints:@[
        [_panel.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_panel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_panel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_panel.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    if ([IVLSettings boolForKey:IVLKeyOpenPlayer]) {
        [self setShowPlayer:YES animated:NO];
    } else if ([IVLSettings boolForKey:IVLKeyImmersivePlayer]) {
        [self setShowPlayer:YES animated:NO];
        [_panel setLyricsMode:YES animated:NO];
    }
}

/// Switch between the lyrics list and the Apple Music-style player page (tap the header artwork).
- (void)setShowPlayer:(BOOL)show animated:(BOOL)animated {
    _showPlayer = show;
    [_panel setArtwork:_artwork.image];
    if (show) { _panel.hidden = NO; [_panel refresh]; }
    if (show) [self.view bringSubviewToFront:_panel];
    void (^changes)(void) = ^{
        self->_panel.alpha = show ? 1 : 0;
        self->_followPill.alpha = 0;
    };
    void (^done)(BOOL) = ^(BOOL f) { if (!self->_showPlayer) self->_panel.hidden = YES; };
    if (animated) [UIView animateWithDuration:0.3 animations:changes completion:done];
    else { changes(); done(YES); }
    [self refreshMoreMenu];
}

- (void)toggleShowPlayer { [self setShowPlayer:!_showPlayer animated:YES]; }

- (void)openRecognizer {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[IVLRecognizerViewController new]];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)buildStateView {
    _stateIcon = [UIImageView new];
    _stateIcon.tintColor = [UIColor colorWithWhite:1 alpha:0.6];
    _stateIcon.contentMode = UIViewContentModeScaleAspectFit;
    [_stateIcon.heightAnchor constraintEqualToConstant:44].active = YES;
    _stateLabel = [UILabel new];
    _stateLabel.numberOfLines = 0;
    _stateLabel.textAlignment = NSTextAlignmentCenter;
    _stateLabel.textColor = [UIColor colorWithWhite:1 alpha:0.8];
    _stateLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    _spinner.color = UIColor.whiteColor;

    _retryButton = [self pillButton:IVLLoc(@"retry") symbol:@"arrow.clockwise" action:@selector(reload)];
    _searchButton = [self pillButton:IVLLoc(@"choose_provider") symbol:@"list.bullet.rectangle" action:@selector(openProviderPicker)];
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[_retryButton, _searchButton]];
    buttons.axis = UILayoutConstraintAxisVertical;
    buttons.spacing = 10;

    _stateView = [[UIStackView alloc] initWithArrangedSubviews:@[_spinner, _stateIcon, _stateLabel, buttons]];
    _stateView.axis = UILayoutConstraintAxisVertical;
    _stateView.alignment = UIStackViewAlignmentCenter;
    _stateView.spacing = 16;
    _stateView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_stateView];
    [NSLayoutConstraint activateConstraints:@[
        [_stateView.centerXAnchor constraintEqualToAnchor:_tableHost.centerXAnchor],
        [_stateView.centerYAnchor constraintEqualToAnchor:_tableHost.centerYAnchor],
        [_stateView.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:32],
        [_stateView.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-32],
    ]];
}

- (UIButton *)pillButton:(NSString *)title symbol:(NSString *)symbol action:(SEL)sel {
    UIButtonConfiguration *cfg = [UIButtonConfiguration filledButtonConfiguration];
    cfg.title = title;
    cfg.image = [UIImage systemImageNamed:symbol];
    cfg.imagePadding = 8;
    cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    cfg.baseBackgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
    cfg.baseForegroundColor = UIColor.whiteColor;
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(12, 20, 12, 20);
    UIButton *b = [UIButton buttonWithConfiguration:cfg primaryAction:nil];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)buildOverlays {
    _followPill = [self pillButton:IVLLoc(@"back_to_current") symbol:@"arrow.down.to.line" action:@selector(followNow)];
    _followPill.alpha = 0;
    _followPill.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_followPill];

    __weak typeof(self) weakSelf = self;
    UIButton *(^step)(NSString *, NSInteger) = ^UIButton *(NSString *title, NSInteger delta) {
        UIButtonConfiguration *cfg = [UIButtonConfiguration filledButtonConfiguration];
        cfg.title = title;
        cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        cfg.baseBackgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
        cfg.baseForegroundColor = UIColor.whiteColor;
        cfg.contentInsets = NSDirectionalEdgeInsetsMake(10, 8, 10, 8);
        UIButton *b = [UIButton buttonWithConfiguration:cfg primaryAction:[UIAction actionWithHandler:^(UIAction *a) {
            [weakSelf adjustOffset:delta];
        }]];
        return b;
    };
    _offsetLabel = [UILabel new];
    _offsetLabel.textColor = UIColor.whiteColor;
    _offsetLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightBold];
    _offsetLabel.textAlignment = NSTextAlignmentCenter;
    _offsetLabel.userInteractionEnabled = YES;
    _offsetLabel.numberOfLines = 2;
    [_offsetLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(resetOffset)]];
    [_offsetLabel.widthAnchor constraintGreaterThanOrEqualToConstant:84].active = YES;

    _offsetPanel = [[UIStackView alloc] initWithArrangedSubviews:@[step(@"−0.5", -500), step(@"−0.1", -100), _offsetLabel, step(@"+0.1", 100), step(@"+0.5", 500)]];
    _offsetPanel.axis = UILayoutConstraintAxisHorizontal;
    _offsetPanel.spacing = 8;
    _offsetPanel.alignment = UIStackViewAlignmentCenter;
    _offsetPanel.distribution = UIStackViewDistributionFill;
    _offsetPanel.layoutMargins = UIEdgeInsetsMake(10, 12, 10, 12);
    _offsetPanel.layoutMarginsRelativeArrangement = YES;
    _offsetPanel.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.92];
    _offsetPanel.layer.cornerRadius = 22;
    _offsetPanel.hidden = YES;
    _offsetPanel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_offsetPanel];

    _toast = [UILabel new];
    _toast.textColor = UIColor.blackColor;
    _toast.backgroundColor = UIColor.whiteColor;
    _toast.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    _toast.textAlignment = NSTextAlignmentCenter;
    _toast.layer.cornerRadius = 16;
    _toast.clipsToBounds = YES;
    _toast.alpha = 0;
    _toast.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_toast];

    [NSLayoutConstraint activateConstraints:@[
        [_followPill.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_followPill.bottomAnchor constraintEqualToAnchor:_toolbar.topAnchor constant:-12],
        [_offsetPanel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_offsetPanel.bottomAnchor constraintEqualToAnchor:_toolbar.topAnchor constant:-10],
        [_offsetPanel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:12],
        [_toast.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_toast.topAnchor constraintEqualToAnchor:_header.bottomAnchor constant:8],
        [_toast.heightAnchor constraintEqualToConstant:32],
        [_toast.widthAnchor constraintGreaterThanOrEqualToConstant:120],
    ]];
}

#pragma mark Content

- (void)trackChanged {
    IVLTrack *t = [IVLPlaybackManager shared].track;
    _titleLabel.text = t.title ?: IVLLoc(@"nothing_playing");
    _artistLabel.text = t.artist;
    _artwork.image = t.artworkImage;
    _bgImage.image = t.artworkImage;
    [_panel setArtwork:t.artworkImage];
    NSString *url = t.artworkURL;
    IVLLoadImage(url, ^(UIImage *img) {
        if (!img || ![[IVLPlaybackManager shared].track.artworkURL isEqualToString:url]) return;
        [UIView transitionWithView:self.view duration:0.4 options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction animations:^{
            self->_artwork.image = img;
            self->_bgImage.image = img;
            [self->_panel setArtwork:img];
        } completion:nil];
        if ([IVLTheme style] == 2) [self applyBackgroundStyle];
    });
    if ([IVLTheme style] == 2) [self applyBackgroundStyle];
    [self refreshOffsetLabel];
    [self lyricsChanged];
}

- (void)lyricsChanged {
    IVLPlaybackManager *m = [IVLPlaybackManager shared];
    IVLLyrics *ly = m.lyrics;
    BOOL showBreaks = [IVLSettings boolForKey:IVLKeyShowBreaks];
    NSMutableArray *lines = [NSMutableArray array];
    for (IVLLyricLine *l in ly.lines) if (showBreaks || !l.instrumental) [lines addObject:l];
    _lines = lines;
    _synced = ly.synced;
    [self updateStyle];
    [self refreshMoreMenu];
    [self refreshToolbar];

    BOOL hasLines = lines.count > 0;
    _table.hidden = !hasLines;
    _stateView.hidden = hasLines;

    if (!hasLines) {
        IVLLyricsState s = m.track ? m.state : IVLLyricsStateIdle;
        BOOL loading = s == IVLLyricsStateLoading;
        loading ? [_spinner startAnimating] : [_spinner stopAnimating];
        _spinner.hidden = !loading;
        _stateIcon.hidden = loading;
        BOOL failed = s == IVLLyricsStateNotFound || s == IVLLyricsStateError || (s == IVLLyricsStateLoaded);
        _retryButton.hidden = !failed;
        _searchButton.hidden = !failed;
        switch (s) {
            case IVLLyricsStateLoading: _stateLabel.text = IVLLoc(@"loading"); break;
            case IVLLyricsStateNotFound:
            case IVLLyricsStateLoaded:
                _stateIcon.image = [UIImage systemImageNamed:@"text.magnifyingglass"];
                _stateLabel.text = IVLLoc(@"not_found"); break;
            case IVLLyricsStateError:
                _stateIcon.image = [UIImage systemImageNamed:@"wifi.exclamationmark"];
                _stateLabel.text = IVLLoc(@"error"); break;
            default:
                _stateIcon.image = [UIImage systemImageNamed:@"music.note"];
                _stateLabel.text = [NSString stringWithFormat:@"%@\n\n%@", IVLLoc(@"nothing_playing"), [m diagnostics]];
                _retryButton.hidden = NO;
                break;
        }
    }

    UILabel *header = nil;
    if (hasLines && !_synced) {
        header = [UILabel new];
        header.text = IVLLoc(@"unsynced_notice");
        header.textColor = [UIColor colorWithWhite:1 alpha:0.55];
        header.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        header.textAlignment = NSTextAlignmentCenter;
        header.frame = CGRectMake(0, 0, 10, 36);
    }
    _table.tableHeaderView = header;

    CGPoint keep = _table.contentOffset;
    BOOL sameLyrics = ly != nil && ly == _shownLyrics;
    _shownLyrics = ly;
    [self applyInsets];
    [_table reloadData];
    if (!_synced) {
        _activeIndex = -1;
        [_table layoutIfNeeded];
        if (!sameLyrics) [_table setContentOffset:CGPointMake(0, -_table.contentInset.top) animated:NO];
        else _table.contentOffset = keep;
    } else if (sameLyrics && !_following) {
        [_table layoutIfNeeded];
        _table.contentOffset = keep;
    } else {
        _activeIndex = -1;
        _following = YES;
        [self hideFollowPill];
        [_table layoutIfNeeded];
        [self tick];
    }
}

- (void)updateStyle {
    _style.fontSize = MAX(14, MIN(56, [IVLSettings doubleForKey:IVLKeyFontSize]));
    _style.alignment = [IVLSettings integerForKey:IVLKeyAlignment] == 1 ? NSTextAlignmentCenter : NSTextAlignmentLeft;
    _style.karaoke = [IVLSettings boolForKey:IVLKeyKaraoke];
    _style.synced = _synced;
}

- (void)settingsChanged:(NSNotification *)n {
    NSString *key = n.object;
    if ([key isEqualToString:IVLKeySongOffsets] || [key isEqualToString:IVLKeyGlobalOffset]) { [self refreshOffsetLabel]; return; }
    if ([key isEqualToString:IVLKeyBackground] || [key isEqualToString:IVLKeyBackgroundColor]) { [self applyBackgroundStyle]; return; }
    if ([key isEqualToString:IVLKeyAccentColor]) { [_table reloadData]; return; }
    if ([key isEqualToString:IVLKeyFontSize] || [key isEqualToString:IVLKeyAlignment] || [key isEqualToString:IVLKeyKaraoke]) {
        [self updateStyle];
        [_table reloadData];
        if (_following) dispatch_async(dispatch_get_main_queue(), ^{ [self scrollToActiveAnimated:NO]; });
        [self refreshToolbar];
        return;
    }
    if ([key isEqualToString:IVLKeyShowBreaks]) { [self lyricsChanged]; return; }
    [self refreshToolbar];
}

- (void)refreshToolbar {
    IVLSetToolOn(_trButton, [IVLSettings boolForKey:IVLKeyTranslation]);
    NSInteger pron = [IVLSettings integerForKey:IVLKeyPronunciation];
    IVLSetToolOn(_pronButton, pron != 0);
    IVLSetToolOn(_sizeButton, NO);
    IVLSetToolOn(_syncButton, !_offsetPanel.hidden);
    IVLSetToolOn(_settingsButton, NO);

    __weak typeof(self) ws = self;
    NSArray *pronOpts = @[@[IVLLoc(@"off"), @0], @[IVLLoc(@"romaji"), @1], @[IVLLoc(@"kana"), @2]];
    NSMutableArray *pronActions = [NSMutableArray array];
    for (NSArray *o in pronOpts) {
        UIAction *a = [UIAction actionWithTitle:o[0] image:nil identifier:nil handler:^(UIAction *x) {
            [IVLSettings setObject:o[1] forKey:IVLKeyPronunciation];
            [ws refreshToolbar];
        }];
        a.state = [o[1] integerValue] == pron ? UIMenuElementStateOn : UIMenuElementStateOff;
        [pronActions addObject:a];
    }
    _pronButton.menu = [UIMenu menuWithTitle:IVLLoc(@"pronunciation") children:pronActions];

    double size = [IVLSettings doubleForKey:IVLKeyFontSize];
    NSArray *sizes = @[@[IVLLoc(@"small"), @22], @[IVLLoc(@"medium"), @28], @[IVLLoc(@"large"), @34], @[IVLLoc(@"xlarge"), @42]];
    NSMutableArray *sizeActions = [NSMutableArray array];
    for (NSArray *o in sizes) {
        UIAction *a = [UIAction actionWithTitle:o[0] image:nil identifier:nil handler:^(UIAction *x) {
            [IVLSettings setObject:o[1] forKey:IVLKeyFontSize];
        }];
        a.state = fabs([o[1] doubleValue] - size) < 0.5 ? UIMenuElementStateOn : UIMenuElementStateOff;
        [sizeActions addObject:a];
    }
    UIAction *center = [UIAction actionWithTitle:IVLLoc(@"align_center") image:[UIImage systemImageNamed:@"text.aligncenter"] identifier:nil handler:^(UIAction *x) {
        [IVLSettings setObject:@([IVLSettings integerForKey:IVLKeyAlignment] == 1 ? 0 : 1) forKey:IVLKeyAlignment];
    }];
    center.state = [IVLSettings integerForKey:IVLKeyAlignment] == 1 ? UIMenuElementStateOn : UIMenuElementStateOff;
    UIMenu *sizeMenu = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:sizeActions];
    _sizeButton.menu = [UIMenu menuWithTitle:IVLLoc(@"pinch_hint") children:@[sizeMenu, center]];
}

- (void)refreshMoreMenu {
    IVLPlaybackManager *m = [IVLPlaybackManager shared];
    __weak typeof(self) ws = self;
    NSMutableArray *items = [NSMutableArray array];
    [items addObject:[UIAction actionWithTitle:IVLLoc(@"choose_provider") image:[UIImage systemImageNamed:@"list.bullet.rectangle"] identifier:nil handler:^(UIAction *a) { [ws openProviderPicker]; }]];
    [items addObject:[UIAction actionWithTitle:IVLLoc(@"search_lyrics") image:[UIImage systemImageNamed:@"magnifyingglass"] identifier:nil handler:^(UIAction *a) { [ws openSearch]; }]];
    [items addObject:[UIAction actionWithTitle:IVLLoc(@"reload") image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(UIAction *a) { [ws reload]; }]];
    if (m.lyrics) {
        [items addObject:[UIAction actionWithTitle:IVLLoc(@"copy_lyrics") image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *a) {
            UIPasteboard.generalPasteboard.string = [[IVLPlaybackManager shared].lyrics plainText];
            [ws showToast:IVLLoc(@"copied")];
        }]];
    }
    if (_showPlayer && [IVLSettings boolForKey:IVLKeyImmersivePlayer]) {
        BOOL inAMLyrics = _panel.lyricsMode;
        [items addObject:[UIAction actionWithTitle:(inAMLyrics ? IVLLoc(@"show_player") : IVLLoc(@"show_lyrics"))
                                             image:[UIImage systemImageNamed:(inAMLyrics ? @"play.square" : @"quote.bubble")]
                                        identifier:nil
                                           handler:^(UIAction *a) { [ws->_panel toggleLyricsMode]; }]];
    } else {
        [items addObject:[UIAction actionWithTitle:(_showPlayer ? IVLLoc(@"show_lyrics") : IVLLoc(@"show_player"))
                                             image:[UIImage systemImageNamed:(_showPlayer ? @"quote.bubble" : @"play.square")]
                                        identifier:nil
                                           handler:^(UIAction *a) { [ws toggleShowPlayer]; }]];
    }
    [items addObject:[UIAction actionWithTitle:IVLLoc(@"recognize") image:[UIImage systemImageNamed:@"shazam.logo"] identifier:nil handler:^(UIAction *a) { [ws openRecognizer]; }]];
    NSString *sleep = [IVLSleepTimer shared].active ? [NSString stringWithFormat:@"%@（%@）", IVLLoc(@"sleep_timer"), [[IVLSleepTimer shared] statusText]] : IVLLoc(@"sleep_timer");
    [items addObject:[UIAction actionWithTitle:sleep image:[UIImage systemImageNamed:@"moon.zzz"] identifier:nil handler:^(UIAction *a) { [ws openSleepTimer]; }]];
    [items addObject:[UIAction actionWithTitle:IVLLoc(@"settings") image:[UIImage systemImageNamed:@"gearshape"] identifier:nil handler:^(UIAction *a) { [ws openSettings]; }]];
    if (m.lyrics.source.length) {
        NSString *info = [NSString stringWithFormat:IVLLoc(@"source_fmt"), m.lyrics.source,
                          m.lyrics.karaoke ? IVLLoc(@"sync_word") : (m.lyrics.synced ? IVLLoc(@"sync_line") : IVLLoc(@"sync_none"))];
        UIAction *src = [UIAction actionWithTitle:info image:[UIImage systemImageNamed:@"info.circle"] identifier:nil handler:^(UIAction *a) {}];
        src.attributes = UIMenuElementAttributesDisabled;
        [items addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[src]]];
    }
    _moreButton.menu = [UIMenu menuWithTitle:@"" children:items];
    _panel.moreMenu = _moreButton.menu;
}

#pragma mark Sync loop

- (NSInteger)indexForTime:(NSInteger)ms {
    NSInteger lo = 0, hi = (NSInteger)_lines.count - 1, found = -1;
    while (lo <= hi) {
        NSInteger mid = (lo + hi) / 2;
        if (_lines[mid].startMs <= ms) { found = mid; lo = mid + 1; } else hi = mid - 1;
    }
    return found;
}

- (void)setHeaderPlaying:(BOOL)playing {
    _shownHeaderPlaying = playing;
    UIImageSymbolConfiguration *sc = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightBold];
    [_playButton setImage:[UIImage systemImageNamed:(playing ? @"pause.fill" : @"play.fill") withConfiguration:sc] forState:UIControlStateNormal];
}

- (void)headerPlayTapped {
    [[UIImpactFeedbackGenerator new] impactOccurred];
    BOOL next = ![IVLRemoteControl isPlaying];
    [IVLRemoteControl togglePlayPause];
    [self setHeaderPlaying:next];
}

- (void)tick {
    BOOL playing = [IVLRemoteControl isPlaying];
    if (playing != _shownHeaderPlaying) [self setHeaderPlaying:playing];
    if (_showPlayer) [_panel refresh];
    if (!_synced || !_lines.count || _table.hidden) return;
    NSInteger t = [[IVLPlaybackManager shared] currentTimeMs];
    NSInteger idx = [self indexForTime:t];
    if (idx != _activeIndex) {
        _activeIndex = idx;
        for (IVLLyricCell *c in _table.visibleCells) {
            NSIndexPath *ip = [_table indexPathForCell:c];
            if (ip) [c setActive:(ip.row == idx) past:(ip.row < idx) animated:YES];
        }
        if (_following) [self scrollToActiveAnimated:YES];
    }
    if (idx >= 0) {
        IVLLyricCell *c = (IVLLyricCell *)[_table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:idx inSection:0]];
        [c updateTime:t];
    }
}

- (void)scrollToActiveAnimated:(BOOL)animated {
    if (_activeIndex < 0 || _activeIndex >= (NSInteger)_lines.count) {
        [_table setContentOffset:CGPointMake(0, -_table.contentInset.top) animated:animated];
        return;
    }
    CGRect r = [_table rectForRowAtIndexPath:[NSIndexPath indexPathForRow:_activeIndex inSection:0]];
    CGFloat h = _table.bounds.size.height;
    CGFloat y = r.origin.y - h * 0.3;
    CGFloat minY = -_table.contentInset.top;
    CGFloat maxY = MAX(minY, _table.contentSize.height + _table.contentInset.bottom - h);
    y = MAX(minY, MIN(maxY, y));
    [_table setContentOffset:CGPointMake(0, y) animated:animated];
}

- (void)followNow {
    _following = YES;
    [_resumeTimer invalidate];
    [self hideFollowPill];
    [self scrollToActiveAnimated:YES];
}

- (void)showFollowPill {
    if (!_synced) return;
    [UIView animateWithDuration:0.2 animations:^{ self->_followPill.alpha = 1; }];
}

- (void)hideFollowPill {
    [UIView animateWithDuration:0.2 animations:^{ self->_followPill.alpha = 0; }];
}

- (void)scheduleResume {
    [_resumeTimer invalidate];
    NSInteger sec = [IVLSettings integerForKey:IVLKeyAutoResume];
    if (sec <= 0 || !_synced) return;
    __weak typeof(self) ws = self;
    _resumeTimer = [NSTimer scheduledTimerWithTimeInterval:sec repeats:NO block:^(NSTimer *t) { [ws followNow]; }];
}

#pragma mark UIScrollViewDelegate

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    if (!_synced) return;
    _following = NO;
    [_resumeTimer invalidate];
    [self showFollowPill];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (!decelerate) [self scheduleResume];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView { [self scheduleResume]; }

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _lines.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    IVLLyricCell *c = [tableView dequeueReusableCellWithIdentifier:[IVLLyricCell reuseID] forIndexPath:indexPath];
    [c configureWithLine:_lines[indexPath.row] style:_style active:(indexPath.row == _activeIndex) past:(indexPath.row < _activeIndex)];
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!_synced) return;
    IVLLyricLine *l = _lines[indexPath.row];
    [[IVLPlaybackManager shared] seekToMs:l.startMs];
    [[UIImpactFeedbackGenerator new] impactOccurred];
    [self followNow];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    IVLLyricLine *l = _lines[indexPath.row];
    if (l.instrumental) return nil;
    __weak typeof(self) ws = self;
    BOOL synced = _synced;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *suggested) {
        NSMutableArray *a = [NSMutableArray array];
        if (synced) {
            [a addObject:[UIAction actionWithTitle:IVLLoc(@"play_from_here") image:[UIImage systemImageNamed:@"play.fill"] identifier:nil handler:^(UIAction *x) {
                [[IVLPlaybackManager shared] seekToMs:l.startMs];
                [ws followNow];
            }]];
            [a addObject:[UIAction actionWithTitle:IVLLoc(@"sync_here") image:[UIImage systemImageNamed:@"scope"] identifier:nil handler:^(UIAction *x) {
                IVLPlaybackManager *m = [IVLPlaybackManager shared];
                NSInteger song = l.startMs - [m rawTimeMs] - [IVLSettings integerForKey:IVLKeyGlobalOffset];
                [m setSongOffsetMs:song];
                [ws showToast:[NSString stringWithFormat:IVLLoc(@"offset_set_fmt"), song / 1000.0]];
                [ws followNow];
            }]];
        }
        [a addObject:[UIAction actionWithTitle:IVLLoc(@"share_image") image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(UIAction *x) {
            [ws shareLine:l];
        }]];
        [a addObject:[UIAction actionWithTitle:IVLLoc(@"copy_line") image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *x) {
            NSMutableArray *parts = [NSMutableArray arrayWithObject:l.text];
            if (l.pronunciation.length) [parts addObject:l.pronunciation];
            if (l.translation.length) [parts addObject:l.translation];
            UIPasteboard.generalPasteboard.string = [parts componentsJoinedByString:@"\n"];
            [ws showToast:IVLLoc(@"copied")];
        }]];
        return [UIMenu menuWithTitle:@"" children:a];
    }];
}

#pragma mark Actions

/// SimpMusic-style "share lyrics as image": the line (and its neighbours) over the blurred artwork.
- (void)shareLine:(IVLLyricLine *)line {
    NSUInteger idx = [_lines indexOfObject:line];
    NSMutableArray *texts = [NSMutableArray array];
    for (NSInteger i = (NSInteger)idx; i >= 0 && i < (NSInteger)_lines.count && texts.count < 3; i++) {
        if (!_lines[i].instrumental && _lines[i].text.length) [texts addObject:_lines[i].text];
    }
    if (!texts.count) [texts addObject:line.text ?: @""];
    IVLTrack *t = [IVLPlaybackManager shared].track;
    UIImage *img = IVLLyricsShareImage(texts, line.translation, t.title ?: @"", t.artist ?: @"", _artwork.image);
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[img] applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.view;
    [self presentViewController:share animated:YES completion:nil];
}

- (void)openSleepTimer {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[IVLSleepTimerViewController new]];
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) nav.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.mediumDetent];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)reload {
    IVLPlaybackManager *m = [IVLPlaybackManager shared];
    if (m.track) [m reloadLyrics]; else [m refreshNow];
}

- (void)openProviderPicker {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[IVLProviderPickerViewController new]];
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)openSearch {
    IVLSearchViewController *s = [IVLSearchViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:s];
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)openSettings { IVLPresentSettings(self); }

- (void)toggleTranslation {
    BOOL on = ![IVLSettings boolForKey:IVLKeyTranslation];
    [IVLSettings setBool:on forKey:IVLKeyTranslation];
    [[UISelectionFeedbackGenerator new] selectionChanged];
    if (on) [self showToast:IVLLoc(@"translating")];
}

- (void)translationLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[IVLLanguagePickerViewController new]];
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)toggleOffsetPanel {
    BOOL show = _offsetPanel.hidden;
    if (show) { _offsetPanel.hidden = NO; _offsetPanel.alpha = 0; }
    [UIView animateWithDuration:0.2 animations:^{ self->_offsetPanel.alpha = show ? 1 : 0; } completion:^(BOOL f) {
        if (!show) self->_offsetPanel.hidden = YES;
    }];
    if (show) _followPill.alpha = 0;
    [self refreshOffsetLabel];
    IVLSetToolOn(_syncButton, show);
}

- (void)adjustOffset:(NSInteger)delta {
    IVLPlaybackManager *m = [IVLPlaybackManager shared];
    [m setSongOffsetMs:[m songOffsetMs] + delta];
    [[UISelectionFeedbackGenerator new] selectionChanged];
}

- (void)resetOffset {
    [[IVLPlaybackManager shared] setSongOffsetMs:0];
    [[UIImpactFeedbackGenerator new] impactOccurred];
}

- (void)refreshOffsetLabel {
    NSInteger ms = [[IVLPlaybackManager shared] songOffsetMs];
    _offsetLabel.text = [NSString stringWithFormat:@"%@\n%+.1fs", IVLLoc(@"offset_song"), ms / 1000.0];
    _offsetLabel.accessibilityHint = IVLLoc(@"reset");
}

- (void)pinch:(UIPinchGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) _pinchBase = [IVLSettings doubleForKey:IVLKeyFontSize];
    if (g.state != UIGestureRecognizerStateChanged) return;
    double size = round(MAX(16, MIN(52, _pinchBase * g.scale)));
    if (fabs(size - [IVLSettings doubleForKey:IVLKeyFontSize]) >= 2) [IVLSettings setObject:@(size) forKey:IVLKeyFontSize];
}

- (void)dismissPan:(UIPanGestureRecognizer *)g {
    CGFloat ty = MAX(0, [g translationInView:self.view].y);
    switch (g.state) {
        case UIGestureRecognizerStateChanged:
            self.view.transform = CGAffineTransformMakeTranslation(0, ty);
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            CGFloat vy = [g velocityInView:self.view].y;
            if (ty > 140 || vy > 900) {
                [UIView animateWithDuration:0.22 animations:^{
                    self.view.transform = CGAffineTransformMakeTranslation(0, self.view.bounds.size.height);
                } completion:^(BOOL f) {
                    [self dismissViewControllerAnimated:NO completion:nil];
                }];
            } else {
                [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0 options:0 animations:^{
                    self.view.transform = CGAffineTransformIdentity;
                } completion:nil];
            }
            break;
        }
        default: break;
    }
}

- (void)showToast:(NSString *)text {
    _toast.text = [NSString stringWithFormat:@"   %@   ", text];
    [self.view bringSubviewToFront:_toast];
    [UIView animateWithDuration:0.2 animations:^{ self->_toast.alpha = 1; } completion:^(BOOL f) {
        [UIView animateWithDuration:0.3 delay:1.4 options:UIViewAnimationOptionAllowUserInteraction animations:^{ self->_toast.alpha = 0; } completion:nil];
    }];
}

@end
