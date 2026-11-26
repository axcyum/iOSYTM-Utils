#import "IVLCoverFlow.h"
#import "IVLSettings.h"
#import "IVLPlaybackManager.h"
#import "IVLLyricsService+Private.h"
#import "IVLRemoteControl.h"
#import "IVLLocalization.h"
#import <QuartzCore/QuartzCore.h>

static NSCache<NSString *, UIImage *> *IVLCFImageCache(void) {
    static NSCache *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        c = [NSCache new];
        c.countLimit = 80;
    });
    return c;
}

#pragma mark - 3D Cover Card (with iOS 6 mirror reflection)

@interface IVLCoverFlowCard : UIView
@property (nonatomic, strong) UIImageView *artView;
@property (nonatomic, strong) UIImageView *reflectionView;
@property (nonatomic, strong) CAGradientLayer *reflectionMask;
@property (nonatomic, strong) UIView *playingDot;
@property (nonatomic, copy) NSString *artURL;
@property (nonatomic, assign) NSInteger index;
@end

@implementation IVLCoverFlowCard

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.clipsToBounds = NO;
        self.layer.allowsEdgeAntialiasing = YES;

        _artView = [UIImageView new];
        _artView.contentMode = UIViewContentModeScaleAspectFill;
        _artView.clipsToBounds = YES;
        _artView.layer.cornerRadius = 4.0;
        _artView.layer.borderWidth = 0.5;
        _artView.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.16].CGColor;
        _artView.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
        [self addSubview:_artView];

        _reflectionView = [UIImageView new];
        _reflectionView.contentMode = UIViewContentModeScaleAspectFill;
        _reflectionView.clipsToBounds = YES;
        _reflectionView.layer.cornerRadius = 4.0;
        _reflectionView.transform = CGAffineTransformMakeScale(1.0, -1.0);
        _reflectionView.alpha = 0.36;
        [self addSubview:_reflectionView];

        _reflectionMask = [CAGradientLayer layer];
        // Since reflectionView is vertically flipped, y=1.0 is the top (closest to artwork) and y=0.0 is the bottom.
        _reflectionMask.colors = @[
            (id)[UIColor colorWithWhite:0 alpha:0.0].CGColor,
            (id)[UIColor colorWithWhite:0 alpha:0.0].CGColor,
            (id)[UIColor colorWithWhite:0 alpha:1.0].CGColor,
        ];
        _reflectionMask.locations = @[@0.0, @0.42, @1.0];
        _reflectionMask.startPoint = CGPointMake(0.5, 0.0);
        _reflectionMask.endPoint = CGPointMake(0.5, 1.0);
        _reflectionView.layer.mask = _reflectionMask;

        _playingDot = [UIView new];
        _playingDot.backgroundColor = [UIColor colorWithRed:1.0 green:0.18 blue:0.33 alpha:1.0];
        _playingDot.layer.cornerRadius = 4.0;
        _playingDot.layer.borderWidth = 1.0;
        _playingDot.layer.borderColor = UIColor.blackColor.CGColor;
        _playingDot.hidden = YES;
        [self addSubview:_playingDot];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    _artView.frame = CGRectMake(0, 0, w, w);
    _reflectionView.frame = CGRectMake(0, w + 2.0, w, w * 0.55);
    _reflectionMask.frame = _reflectionView.bounds;
    _playingDot.frame = CGRectMake(w - 14.0, 6.0, 8.0, 8.0);
}

- (void)setImage:(UIImage *)img {
    if (!img) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:42 weight:UIImageSymbolWeightLight];
        UIImage *ph = [[UIImage systemImageNamed:@"music.note" withConfiguration:cfg]
                       imageWithTintColor:[UIColor colorWithWhite:0.45 alpha:1.0] renderingMode:UIImageRenderingModeAlwaysOriginal];
        _artView.contentMode = UIViewContentModeCenter;
        _artView.image = ph;
        _reflectionView.image = nil;
        return;
    }
    _artView.contentMode = UIViewContentModeScaleAspectFill;
    _artView.image = img;
    _reflectionView.image = img;
}

@end

#pragma mark - Cover Flow View Controller

@interface IVLCoverFlowViewController : UIViewController <UIScrollViewDelegate>
@property (nonatomic, copy) void (^onDismiss)(void);
@property (nonatomic, assign) UIDeviceOrientation targetOrientation;
- (void)reloadQueue;
- (void)applyOrientation:(UIDeviceOrientation)orient animated:(BOOL)animated;
@end

@implementation IVLCoverFlowViewController {
    UIView *_stage;
    CAGradientLayer *_bgGrad;
    UIScrollView *_scroll;
    NSMutableArray<IVLCoverFlowCard *> *_cards;
    NSArray<NSDictionary *> *_items;
    NSInteger _currentIndex;
    CGFloat _cardSize;
    CGFloat _itemStep;

    UILabel *_titleLabel;
    UILabel *_artistLabel;
    UILabel *_countLabel;
    UIButton *_closeBtn;
    UIButton *_prevBtn;
    UIButton *_playBtn;
    UIButton *_nextBtn;
    UIActivityIndicatorView *_spinner;
    NSString *_loadedVideoID;
}

- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
- (BOOL)prefersStatusBarHidden { return YES; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    _cards = [NSMutableArray array];
    _items = @[];

    _stage = [UIView new];
    _stage.backgroundColor = UIColor.blackColor;
    _stage.clipsToBounds = YES;
    [self.view addSubview:_stage];

    _bgGrad = [CAGradientLayer layer];
    _bgGrad.colors = @[
        (id)[UIColor colorWithWhite:0.06 alpha:1.0].CGColor,
        (id)[UIColor colorWithWhite:0.00 alpha:1.0].CGColor,
        (id)[UIColor colorWithWhite:0.04 alpha:1.0].CGColor,
    ];
    _bgGrad.locations = @[@0.0, @0.55, @1.0];
    [_stage.layer addSublayer:_bgGrad];

    _scroll = [UIScrollView new];
    _scroll.delegate = self;
    _scroll.showsHorizontalScrollIndicator = NO;
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.decelerationRate = UIScrollViewDecelerationRateFast;
    _scroll.clipsToBounds = NO;
    [_stage addSubview:_scroll];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    [_scroll addGestureRecognizer:tap];

    _titleLabel = [UILabel new];
    _titleLabel.font = [UIFont systemFontOfSize:19 weight:UIFontWeightBold];
    _titleLabel.textColor = UIColor.whiteColor;
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_stage addSubview:_titleLabel];

    _artistLabel = [UILabel new];
    _artistLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _artistLabel.textColor = [UIColor colorWithWhite:0.68 alpha:1.0];
    _artistLabel.textAlignment = NSTextAlignmentCenter;
    _artistLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_stage addSubview:_artistLabel];

    _countLabel = [UILabel new];
    _countLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    _countLabel.textColor = [UIColor colorWithWhite:0.45 alpha:1.0];
    _countLabel.textAlignment = NSTextAlignmentRight;
    [_stage addSubview:_countLabel];

    _closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *xCfg = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightBold];
    [_closeBtn setImage:[UIImage systemImageNamed:@"xmark" withConfiguration:xCfg] forState:UIControlStateNormal];
    _closeBtn.tintColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    _closeBtn.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    _closeBtn.layer.cornerRadius = 16.0;
    [_closeBtn addTarget:self action:@selector(dismissTapped) forControlEvents:UIControlEventTouchUpInside];
    [_stage addSubview:_closeBtn];

    UIImageSymbolConfiguration *ctlCfg = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold];
    UIImageSymbolConfiguration *playCfg = [UIImageSymbolConfiguration configurationWithPointSize:21 weight:UIImageSymbolWeightBold];

    _prevBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [_prevBtn setImage:[UIImage systemImageNamed:@"backward.fill" withConfiguration:ctlCfg] forState:UIControlStateNormal];
    _prevBtn.tintColor = [UIColor colorWithWhite:0.9 alpha:1.0];
    [_prevBtn addTarget:self action:@selector(prevTapped) forControlEvents:UIControlEventTouchUpInside];
    [_stage addSubview:_prevBtn];

    _playBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [_playBtn setImage:[UIImage systemImageNamed:@"pause.fill" withConfiguration:playCfg] forState:UIControlStateNormal];
    _playBtn.tintColor = UIColor.whiteColor;
    [_playBtn addTarget:self action:@selector(playPauseTapped) forControlEvents:UIControlEventTouchUpInside];
    [_stage addSubview:_playBtn];

    _nextBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [_nextBtn setImage:[UIImage systemImageNamed:@"forward.fill" withConfiguration:ctlCfg] forState:UIControlStateNormal];
    _nextBtn.tintColor = [UIColor colorWithWhite:0.9 alpha:1.0];
    [_nextBtn addTarget:self action:@selector(nextTapped) forControlEvents:UIControlEventTouchUpInside];
    [_stage addSubview:_nextBtn];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.color = UIColor.whiteColor;
    _spinner.hidesWhenStopped = YES;
    [_stage addSubview:_spinner];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(trackDidChange) name:IVLTrackDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(artworkDidChange) name:IVLArtworkDidChangeNotification object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self applyOrientation:_targetOrientation animated:NO];
}

- (void)applyOrientation:(UIDeviceOrientation)orient animated:(BOOL)animated {
    _targetOrientation = orient;
    CGRect b = self.view.bounds;
    if (b.size.width <= 0 || b.size.height <= 0) return;

    CGFloat w = MAX(b.size.width, b.size.height);
    CGFloat h = MIN(b.size.width, b.size.height);
    CGFloat angle = (orient == UIDeviceOrientationLandscapeRight) ? -M_PI_2 : M_PI_2;
    // If the window itself is already landscape, no extra rotation needed
    if (b.size.width > b.size.height) angle = 0;

    void (^apply)(void) = ^{
        self->_stage.transform = CGAffineTransformIdentity;
        self->_stage.bounds = CGRectMake(0, 0, w, h);
        self->_stage.center = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
        self->_stage.transform = CGAffineTransformMakeRotation(angle);
        [self layoutStageWithWidth:w height:h];
    };
    if (animated) {
        [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:apply completion:nil];
    } else {
        apply();
    }
}

- (void)layoutStageWithWidth:(CGFloat)w height:(CGFloat)h {
    _bgGrad.frame = CGRectMake(0, 0, w, h);
    CGFloat safeX = 44.0;
    _closeBtn.frame = CGRectMake(safeX, 14.0, 32.0, 32.0);
    _countLabel.frame = CGRectMake(w - safeX - 90.0, 20.0, 90.0, 20.0);

    _cardSize = floor(MIN(h * 0.56, 224.0));
    _itemStep = floor(_cardSize * 0.42);

    CGFloat scrollH = _cardSize * 1.56;
    CGFloat scrollY = MAX(18.0, (h - scrollH - 76.0) * 0.5);
    _scroll.frame = CGRectMake(0, scrollY, w, scrollH);
    _spinner.center = CGPointMake(w * 0.5, scrollY + _cardSize * 0.5);

    CGFloat hudY = h - 86.0;
    _titleLabel.frame = CGRectMake(safeX + 20.0, hudY, w - (safeX + 20.0) * 2.0, 24.0);
    _artistLabel.frame = CGRectMake(safeX + 20.0, hudY + 24.0, w - (safeX + 20.0) * 2.0, 19.0);

    CGFloat ctrlY = hudY + 48.0;
    CGFloat cx = w * 0.5;
    _playBtn.frame = CGRectMake(cx - 24.0, ctrlY, 48.0, 34.0);
    _prevBtn.frame = CGRectMake(cx - 88.0, ctrlY, 44.0, 34.0);
    _nextBtn.frame = CGRectMake(cx + 44.0, ctrlY, 44.0, 34.0);

    [self layoutCards];
    [self scrollToIndex:_currentIndex animated:NO];
    [self update3DTransforms];
}

- (void)rebuildCards {
    for (IVLCoverFlowCard *c in _cards) [c removeFromSuperview];
    [_cards removeAllObjects];

    NSString *playingVID = [IVLPlaybackManager shared].track.youtubeVideoID ?: @"";
    for (NSUInteger i = 0; i < _items.count; i++) {
        NSDictionary *item = _items[i];
        IVLCoverFlowCard *card = [[IVLCoverFlowCard alloc] initWithFrame:CGRectMake(0, 0, _cardSize, _cardSize * 1.55)];
        card.index = (NSInteger)i;
        card.artURL = item[@"artworkURL"] ?: @"";
        card.playingDot.hidden = !(playingVID.length && [playingVID isEqualToString:item[@"videoId"]]);

        UIImage *cached = card.artURL.length ? [IVLCFImageCache() objectForKey:card.artURL] : nil;
        if (!cached && playingVID.length && [playingVID isEqualToString:item[@"videoId"]]) {
            cached = [IVLPlaybackManager shared].track.artworkImage;
        }
        [card setImage:cached];
        if (!cached && card.artURL.length) [self loadImageForCard:card urlString:card.artURL];

        [_scroll addSubview:card];
        [_cards addObject:card];
    }
    [self layoutCards];
    [self scrollToIndex:_currentIndex animated:NO];
    [self update3DTransforms];
    [self updateHUD];
}

- (void)layoutCards {
    CGFloat w = _scroll.bounds.size.width;
    if (w <= 0 || !_cards.count) {
        _scroll.contentSize = CGSizeZero;
        return;
    }
    CGFloat sideInset = (w - _cardSize) * 0.5;
    CGFloat cardH = _cardSize * 1.55;
    for (NSUInteger i = 0; i < _cards.count; i++) {
        IVLCoverFlowCard *card = _cards[i];
        card.layer.transform = CATransform3DIdentity;
        card.frame = CGRectMake(sideInset + i * _itemStep, 6.0, _cardSize, cardH);
    }
    CGFloat totalW = sideInset * 2.0 + _cardSize + MAX(0, (NSInteger)_cards.count - 1) * _itemStep;
    _scroll.contentSize = CGSizeMake(totalW, _scroll.bounds.size.height);
}

- (void)update3DTransforms {
    CGFloat w = _scroll.bounds.size.width;
    if (w <= 0 || !_cards.count || _itemStep <= 0) return;

    CGFloat centerX = _scroll.contentOffset.x + w * 0.5;
    NSInteger nearest = 0;
    CGFloat nearestDist = CGFLOAT_MAX;

    for (NSUInteger i = 0; i < _cards.count; i++) {
        IVLCoverFlowCard *card = _cards[i];
        CGFloat baseCenterX = (w - _cardSize) * 0.5 + i * _itemStep + _cardSize * 0.5;
        CGFloat rawDist = (baseCenterX - centerX) / _itemStep;
        CGFloat absDist = fabs(rawDist);
        if (absDist < nearestDist) {
            nearestDist = absDist;
            nearest = (NSInteger)i;
        }

        // Cull far-off cards lightly for buttery 60/120fps scrolling
        if (absDist > 12.0) {
            card.hidden = YES;
            continue;
        }
        card.hidden = NO;

        CGFloat clamped = MAX(-1.0, MIN(1.0, rawDist));
        CGFloat angle = -clamped * (58.0 * M_PI / 180.0);
        CGFloat scale = 1.06 - MIN(absDist, 1.0) * 0.24;
        CGFloat pushX = clamped * (_cardSize * 0.34);
        CGFloat zShift = -MIN(absDist, 1.0) * 70.0;

        CATransform3D t = CATransform3DIdentity;
        t.m34 = -1.0 / 620.0;
        t = CATransform3DTranslate(t, pushX, 0, zShift);
        t = CATransform3DRotate(t, angle, 0, 1, 0);
        t = CATransform3DScale(t, scale, scale, 1.0);

        card.layer.transform = t;
        card.layer.zPosition = 1000.0 - absDist * 10.0;
        card.alpha = MAX(0.35, 1.0 - MAX(0.0, absDist - 4.0) * 0.14);
    }

    if (nearest != _currentIndex) {
        _currentIndex = nearest;
        [self updateHUD];
    }
}

- (void)scrollToIndex:(NSInteger)idx animated:(BOOL)animated {
    if (!_cards.count) return;
    idx = MAX(0, MIN((NSInteger)_cards.count - 1, idx));
    _currentIndex = idx;
    CGFloat targetX = idx * _itemStep;
    [_scroll setContentOffset:CGPointMake(targetX, 0) animated:animated];
    [self updateHUD];
}

- (void)updateHUD {
    BOOL playing = [[IVLPlaybackManager shared] isPlaying];
    UIImageSymbolConfiguration *playCfg = [UIImageSymbolConfiguration configurationWithPointSize:21 weight:UIImageSymbolWeightBold];
    [_playBtn setImage:[UIImage systemImageNamed:(playing ? @"pause.fill" : @"play.fill") withConfiguration:playCfg] forState:UIControlStateNormal];

    if (_currentIndex >= 0 && _currentIndex < (NSInteger)_items.count) {
        NSDictionary *item = _items[_currentIndex];
        _titleLabel.text = [item[@"title"] length] ? item[@"title"] : IVLLoc(@"nothing_playing");
        _artistLabel.text = item[@"artist"] ?: @"";
        _countLabel.text = [NSString stringWithFormat:@"%ld / %lu", (long)(_currentIndex + 1), (unsigned long)_items.count];
    } else {
        IVLTrack *t = [IVLPlaybackManager shared].track;
        _titleLabel.text = t.title.length ? t.title : IVLLoc(@"nothing_playing");
        _artistLabel.text = t.artist ?: @"";
        _countLabel.text = @"";
    }
}

- (void)loadImageForCard:(IVLCoverFlowCard *)card urlString:(NSString *)urlStr {
    NSURL *u = [NSURL URLWithString:urlStr];
    if (!u) return;
    __weak IVLCoverFlowCard *weakCard = card;
    [[[NSURLSession sharedSession] dataTaskWithURL:u completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (!data.length) return;
        UIImage *img = [UIImage imageWithData:data];
        if (!img) return;
        [IVLCFImageCache() setObject:img forKey:urlStr];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong IVLCoverFlowCard *sc = weakCard;
            if (sc && [sc.artURL isEqualToString:urlStr]) {
                [UIView transitionWithView:sc duration:0.18 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
                    [sc setImage:img];
                } completion:nil];
            }
        });
    }] resume];
}

#pragma mark - Queue loading

- (void)reloadQueue {
    IVLTrack *track = [IVLPlaybackManager shared].track;
    if (!track) {
        _items = @[];
        [self rebuildCards];
        return;
    }

    // Immediate fallback card for current track while playlist loads
    if (!_items.count || ![_loadedVideoID isEqualToString:track.youtubeVideoID ?: track.videoID]) {
        _items = @[@{
            @"videoId": track.youtubeVideoID ?: @"",
            @"title": track.title ?: @"",
            @"artist": track.artist ?: @"",
            @"artworkURL": track.artworkURL ?: @"",
        }];
        _currentIndex = 0;
        [self rebuildCards];
    }

    // Try reading current playlistId from YTPlayerViewController if available
    NSString *playlistID = nil;
    UIViewController *player = [IVLPlaybackManager shared].player;
    @try {
        if (player && [player respondsToSelector:NSSelectorFromString(@"contentPlaylistID")]) {
            id pl = [player valueForKey:@"contentPlaylistID"];
            if ([pl isKindOfClass:[NSString class]] && [pl length]) playlistID = pl;
        }
    } @catch (__unused NSException *e) {}

    [_spinner startAnimating];
    NSString *reqID = track.youtubeVideoID ?: track.videoID;
    __weak typeof(self) weakSelf = self;
    [[IVLLyricsService shared] youtubeQueueForTrack:track playlistID:playlistID completion:^(NSArray<NSDictionary *> *items, NSInteger selIdx) {
        __strong typeof(weakSelf) ss = weakSelf;
        if (!ss) return;
        [ss->_spinner stopAnimating];
        if (!items.count) return;
        ss->_loadedVideoID = reqID;
        ss->_items = items;
        ss->_currentIndex = selIdx;
        [ss rebuildCards];
    }];
}

- (void)trackDidChange {
    IVLTrack *t = [IVLPlaybackManager shared].track;
    NSString *vid = t.youtubeVideoID ?: @"";
    if (vid.length && _items.count) {
        for (NSUInteger i = 0; i < _items.count; i++) {
            if ([_items[i][@"videoId"] isEqualToString:vid]) {
                for (IVLCoverFlowCard *c in _cards) {
                    c.playingDot.hidden = (c.index != (NSInteger)i);
                }
                [self scrollToIndex:(NSInteger)i animated:YES];
                return;
            }
        }
    }
    [self reloadQueue];
}

- (void)artworkDidChange {
    IVLTrack *t = [IVLPlaybackManager shared].track;
    if (!t.artworkImage) return;
    NSString *vid = t.youtubeVideoID ?: @"";
    for (IVLCoverFlowCard *c in _cards) {
        if (c.index >= 0 && c.index < (NSInteger)_items.count && [vid isEqualToString:_items[c.index][@"videoId"]]) {
            if (!c.artView.image || c.artView.contentMode == UIViewContentModeCenter) [c setImage:t.artworkImage];
        }
    }
}

#pragma mark - UIScrollViewDelegate & Actions

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [self update3DTransforms];
}

- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView withVelocity:(CGPoint)velocity targetContentOffset:(inout CGPoint *)targetContentOffset {
    if (_itemStep <= 0 || !_cards.count) return;
    NSInteger idx = (NSInteger)llround(targetContentOffset->x / _itemStep);
    idx = MAX(0, MIN((NSInteger)_cards.count - 1, idx));
    targetContentOffset->x = idx * _itemStep;
}

- (void)handleTap:(UITapGestureRecognizer *)gr {
    if (!_cards.count) return;
    CGPoint pt = [gr locationInView:_scroll];
    // Find tapped card closest to touch point (prefer front-most zPosition)
    IVLCoverFlowCard *hit = nil;
    CGFloat bestZ = -1e9;
    for (IVLCoverFlowCard *c in _cards) {
        if (c.hidden) continue;
        CGRect f = c.layer.frame;
        if (CGRectContainsPoint(CGRectInset(f, -6, -6), pt) && c.layer.zPosition > bestZ) {
            bestZ = c.layer.zPosition;
            hit = c;
        }
    }
    if (!hit) return;
    if (hit.index != _currentIndex) {
        [self scrollToIndex:hit.index animated:YES];
        return;
    }
    // Tapped center cover: play that track (or toggle play/pause if already playing)
    NSDictionary *item = _items[hit.index];
    NSString *vid = item[@"videoId"];
    NSString *playingVID = [IVLPlaybackManager shared].track.youtubeVideoID ?: @"";
    if (!vid.length || [vid isEqualToString:playingVID]) {
        [self playPauseTapped];
        return;
    }
    [[UIImpactFeedbackGenerator new] impactOccurred];
    NSURL *ytm = [NSURL URLWithString:[NSString stringWithFormat:@"youtubemusic://watch?v=%@", vid]];
    NSURL *web = [NSURL URLWithString:[NSString stringWithFormat:@"https://music.youtube.com/watch?v=%@", vid]];
    UIApplication *app = [UIApplication sharedApplication];
    if (ytm && [app canOpenURL:ytm]) {
        [app openURL:ytm options:@{} completionHandler:nil];
    } else if (web) {
        [app openURL:web options:@{} completionHandler:nil];
    }
}

- (void)prevTapped { [IVLRemoteControl previous]; }
- (void)nextTapped { [IVLRemoteControl next]; }
- (void)playPauseTapped {
    [IVLRemoteControl togglePlayPause];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self updateHUD];
    });
}
- (void)dismissTapped {
    if (self.onDismiss) self.onDismiss();
}

@end

#pragma mark - Cover Flow Manager

@implementation IVLCoverFlowManager {
    UIWindow *_window;
    IVLCoverFlowViewController *_vc;
    BOOL _manuallyDismissed;
    BOOL _started;
}

+ (instancetype)shared {
    static IVLCoverFlowManager *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [self new]; });
    return m;
}

+ (BOOL)shouldBlockNativeFullscreen {
    return [IVLSettings boolForKey:IVLKeyCoverFlow];
}

- (void)start {
    if (_started) return;
    _started = YES;
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(orientationDidChange) name:UIDeviceOrientationDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(settingsDidChange) name:IVLSettingsDidChangeNotification object:nil];
}

- (void)settingsDidChange {
    if (![IVLSettings boolForKey:IVLKeyCoverFlow]) {
        [self hideAnimated:YES];
    }
}

- (void)orientationDidChange {
    if (![IVLSettings boolForKey:IVLKeyCoverFlow]) return;
    UIDeviceOrientation o = [UIDevice currentDevice].orientation;
    if (o == UIDeviceOrientationPortrait) {
        _manuallyDismissed = NO;
        [self hideAnimated:YES];
        return;
    }
    if (o == UIDeviceOrientationLandscapeLeft || o == UIDeviceOrientationLandscapeRight) {
        if (_manuallyDismissed) return;
        if (![IVLPlaybackManager shared].track) return;
        [self showForOrientation:o];
    }
}

- (UIWindowScene *)activeScene {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (s.activationState == UISceneActivationStateForegroundActive && [s isKindOfClass:[UIWindowScene class]]) {
            return (UIWindowScene *)s;
        }
    }
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)s;
    }
    return nil;
}

- (void)showForOrientation:(UIDeviceOrientation)orient {
    if (_window && !_window.hidden) {
        [_vc applyOrientation:orient animated:YES];
        return;
    }
    UIWindowScene *scene = [self activeScene];
    if (!scene) return;
    if (!_window) {
        _window = [[UIWindow alloc] initWithWindowScene:scene];
        _window.windowLevel = UIWindowLevelAlert - 1.0;
        _window.backgroundColor = UIColor.blackColor;
        _vc = [IVLCoverFlowViewController new];
        __weak typeof(self) weakSelf = self;
        _vc.onDismiss = ^{
            __strong typeof(weakSelf) ss = weakSelf;
            if (!ss) return;
            ss->_manuallyDismissed = YES;
            [ss hideAnimated:YES];
        };
        _window.rootViewController = _vc;
    }
    _vc.targetOrientation = orient;
    [_vc reloadQueue];
    _window.alpha = 0.0;
    _window.hidden = NO;
    [_window makeKeyAndVisible];
    [_vc applyOrientation:orient animated:NO];
    [UIView animateWithDuration:0.25 animations:^{
        self->_window.alpha = 1.0;
    }];
}

- (void)hideAnimated:(BOOL)animated {
    if (!_window || _window.hidden) return;
    void (^done)(BOOL) = ^(BOOL finished) {
        self->_window.hidden = YES;
    };
    if (animated) {
        [UIView animateWithDuration:0.22 animations:^{ self->_window.alpha = 0.0; } completion:done];
    } else {
        done(YES);
    }
}

@end
