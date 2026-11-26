#import "IVLCoverFlow.h"
#import "IVLSettings.h"
#import "IVLPlaybackManager.h"
#import "IVLLyricsService+Private.h"
#import "IVLRemoteControl.h"
#import "IVLLocalization.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

@interface IVLCoverFlowManager ()
@property (nonatomic, copy) NSArray<NSDictionary *> *capturedQueue;
@property (nonatomic, copy, nullable) NSString *capturedPlaylistID;
@end

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

    CGFloat hudY = h - 98.0;
    _titleLabel.frame = CGRectMake(safeX + 20.0, hudY, w - (safeX + 20.0) * 2.0, 23.0);
    _artistLabel.frame = CGRectMake(safeX + 20.0, hudY + 23.0, w - (safeX + 20.0) * 2.0, 18.0);

    CGFloat ctrlY = hudY + 44.0;
    CGFloat cx = w * 0.5;
    _playBtn.frame = CGRectMake(cx - 24.0, ctrlY, 48.0, 32.0);
    _prevBtn.frame = CGRectMake(cx - 88.0, ctrlY, 44.0, 32.0);
    _nextBtn.frame = CGRectMake(cx + 44.0, ctrlY, 44.0, 32.0);

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

#pragma mark - Queue helpers (real YTMusic YTIPlaylistPanelRenderer extractor + rotate previous to back)

static NSString *IVLCFFormattedString(id fs) {
    if (!fs) return @"";
    if ([fs isKindOfClass:[NSString class]]) return fs;
    @try {
        if ([fs respondsToSelector:@selector(simpleText)]) {
            id st = [fs performSelector:@selector(simpleText)];
            if ([st isKindOfClass:[NSString class]] && [st length]) return st;
        }
        if ([fs respondsToSelector:@selector(runsArray)]) {
            id runs = [fs performSelector:@selector(runsArray)];
            if ([runs isKindOfClass:[NSArray class]]) {
                NSMutableString *m = [NSMutableString string];
                for (id r in (NSArray *)runs) {
                    if ([r respondsToSelector:@selector(text)]) {
                        id t = [r performSelector:@selector(text)];
                        if ([t isKindOfClass:[NSString class]]) [m appendString:t];
                    }
                }
                if (m.length) return m;
            }
        }
    } @catch (__unused NSException *e) {}
    return @"";
}

static NSString *IVLCFUpgradeCoverURL(NSString *u) {
    if (!u.length) return @"";
    NSURLComponents *comp = [NSURLComponents componentsWithString:u];
    NSString *host = comp.host.lowercaseString ?: @"";
    if ([comp.scheme isEqualToString:@"https"] && ([host hasSuffix:@"googleusercontent.com"] || [host hasSuffix:@"ggpht.com"])) {
        NSString *path = comp.percentEncodedPath ?: @"";
        NSRange eq = [path rangeOfString:@"=" options:NSBackwardsSearch];
        if (eq.location != NSNotFound) path = [path substringToIndex:eq.location];
        return [NSString stringWithFormat:@"https://%@%@=w544-h544-l90-rj", comp.host, path];
    }
    return u;
}

static NSArray<NSDictionary *> *IVLCFExtractFromPanel(id panel, NSString **outPlaylistID) {
    if (!panel) return @[];
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    @try {
        if (outPlaylistID && [panel respondsToSelector:@selector(playlistId)]) {
            id pid = [panel performSelector:@selector(playlistId)];
            if ([pid isKindOfClass:[NSString class]] && [pid length]) *outPlaylistID = pid;
        }
        if (![panel respondsToSelector:@selector(contentsArray)]) return @[];
        id contents = [panel performSelector:@selector(contentsArray)];
        if (![contents isKindOfClass:[NSArray class]]) return @[];

        for (id entry in (NSArray *)contents) {
            id vr = nil;
            if ([entry respondsToSelector:@selector(playlistPanelVideoRenderer)]) {
                vr = [entry performSelector:@selector(playlistPanelVideoRenderer)];
            }
            if (!vr && [entry respondsToSelector:@selector(playlistPanelVideoWrapperRenderer)]) {
                id wrap = [entry performSelector:@selector(playlistPanelVideoWrapperRenderer)];
                if (wrap && [wrap respondsToSelector:@selector(primaryRenderer)]) {
                    id prim = [wrap performSelector:@selector(primaryRenderer)];
                    if (prim && [prim respondsToSelector:@selector(playlistPanelVideoRenderer)]) {
                        vr = [prim performSelector:@selector(playlistPanelVideoRenderer)];
                    }
                }
            }
            if (!vr) continue;
            NSString *vid = nil;
            if ([vr respondsToSelector:@selector(videoId)]) {
                id v = [vr performSelector:@selector(videoId)];
                if ([v isKindOfClass:[NSString class]]) vid = v;
            }
            if (!vid.length || [seen containsObject:vid]) continue;
            [seen addObject:vid];

            NSString *title = [vr respondsToSelector:@selector(title)] ? IVLCFFormattedString([vr performSelector:@selector(title)]) : @"";
            NSString *artist = @"";
            if ([vr respondsToSelector:@selector(shortBylineText)]) {
                artist = IVLCFFormattedString([vr performSelector:@selector(shortBylineText)]);
            }
            if (!artist.length && [vr respondsToSelector:@selector(longBylineText)]) {
                artist = IVLCFFormattedString([vr performSelector:@selector(longBylineText)]);
            }
            // Strip " • 3:27" duration suffix if present in byline
            NSRange dot = [artist rangeOfString:@" • "];
            if (dot.location != NSNotFound) artist = [artist substringToIndex:dot.location];

            NSString *cover = @"";
            if ([vr respondsToSelector:@selector(thumbnail)]) {
                id td = [vr performSelector:@selector(thumbnail)];
                if (td && [td respondsToSelector:@selector(thumbnailsArray)]) {
                    id arr = [td performSelector:@selector(thumbnailsArray)];
                    if ([arr isKindOfClass:[NSArray class]] && [(NSArray *)arr count]) {
                        id last = [(NSArray *)arr lastObject];
                        if ([last respondsToSelector:@selector(URL)]) {
                            id u = [last performSelector:@selector(URL)];
                            if ([u isKindOfClass:[NSString class]]) cover = IVLCFUpgradeCoverURL(u);
                        }
                    }
                }
            }
            [items addObject:@{
                @"videoId": vid,
                @"title": title ?: @"",
                @"artist": artist ?: @"",
                @"artworkURL": cover ?: @"",
            }];
            if (items.count >= 60) break;
        }
    } @catch (__unused NSException *e) {}
    return items;
}

/// Rotates queue so the currently playing track is at index 0, upcoming tracks follow to the right,
/// and previously played tracks wrap around to the back (end) of the list.
static NSArray<NSDictionary *> *IVLRotateQueueForTrack(NSArray<NSDictionary *> *items, IVLTrack *track) {
    if (items.count <= 1 || !track) return items ?: @[];
    NSString *vid = track.youtubeVideoID ?: @"";
    NSString *title = track.title.lowercaseString ?: @"";
    NSInteger matchIdx = NSNotFound;
    for (NSUInteger i = 0; i < items.count; i++) {
        NSDictionary *it = items[i];
        if (vid.length && [vid isEqualToString:it[@"videoId"]]) { matchIdx = (NSInteger)i; break; }
    }
    if (matchIdx == NSNotFound && title.length) {
        for (NSUInteger i = 0; i < items.count; i++) {
            NSString *t = [items[i][@"title"] lowercaseString] ?: @"";
            if ([t isEqualToString:title]) { matchIdx = (NSInteger)i; break; }
        }
    }
    if (matchIdx == NSNotFound || matchIdx == 0) return items;
    NSRange tail = NSMakeRange((NSUInteger)matchIdx, items.count - (NSUInteger)matchIdx);
    NSRange head = NSMakeRange(0, (NSUInteger)matchIdx);
    return [[items subarrayWithRange:tail] arrayByAddingObjectsFromArray:[items subarrayWithRange:head]];
}

/// Safely walks object ivars (shallow BFS) to locate YouTube Music's live YTIPlaylistPanelRenderer
/// or queue item array without triggering unknown KVC keys or crashing.
static void IVLCFScanForQueue(id root, NSMutableArray<NSDictionary *> **outItems, NSString **outPlaylistID) {
    if (!root) return;
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    NSMutableArray *queue = [NSMutableArray arrayWithObject:@[root, @0]];
    NSUInteger steps = 0;

    while (queue.count && steps < 350) {
        NSArray *pair = queue.firstObject;
        [queue removeObjectAtIndex:0];
        id obj = pair[0];
        NSInteger depth = [pair[1] integerValue];
        if (!obj || depth > 5) continue;

        NSValue *ptr = [NSValue valueWithPointer:(__bridge const void *)obj];
        if ([visited containsObject:ptr]) continue;
        [visited addObject:ptr];
        steps++;

        NSString *clsName = NSStringFromClass([obj class]);
        if ([clsName containsString:@"PlaylistPanelRenderer"]) {
            NSString *pl = nil;
            NSArray<NSDictionary *> *extracted = IVLCFExtractFromPanel(obj, &pl);
            if (pl.length && outPlaylistID && !(*outPlaylistID).length) *outPlaylistID = pl;
            if (extracted.count >= 2 && outItems) {
                *outItems = [extracted mutableCopy];
                return;
            }
        }

        // Skip Foundation value/UI leaf classes to keep scanning ultra-fast
        if ([obj isKindOfClass:[NSString class]] || [obj isKindOfClass:[NSNumber class]] ||
            [obj isKindOfClass:[NSData class]] || [obj isKindOfClass:[UIImage class]] ||
            [obj isKindOfClass:[UIColor class]] || [obj isKindOfClass:[UIFont class]] ||
            [obj isKindOfClass:[CALayer class]] || [obj isKindOfClass:[NSLayoutConstraint class]]) {
            continue;
        }

        if ([obj isKindOfClass:[UIViewController class]]) {
            UIViewController *vc = (UIViewController *)obj;
            for (UIViewController *child in vc.childViewControllers) {
                if (child) [queue addObject:@[child, @(depth + 1)]];
            }
        }

        if ([obj isKindOfClass:[NSArray class]]) {
            NSArray *arr = (NSArray *)obj;
            if (arr.count > 0 && arr.count <= 80) {
                // Check if this array directly holds YTIPlaylistPanelVideoRenderer / queue item objects
                NSMutableArray<NSDictionary *> *direct = [NSMutableArray array];
                NSMutableSet<NSString *> *seen = [NSMutableSet set];
                for (id el in arr) {
                    NSString *ec = NSStringFromClass([el class]);
                    if ([ec containsString:@"PlaylistPanelVideo"] || [ec containsString:@"QueueItem"]) {
                        id vr = el;
                        @try {
                            if ([el respondsToSelector:@selector(playlistPanelVideoRenderer)]) {
                                id sub = [el performSelector:@selector(playlistPanelVideoRenderer)];
                                if (sub) vr = sub;
                            }
                            NSString *vid = [vr respondsToSelector:@selector(videoId)] ? [vr performSelector:@selector(videoId)] : nil;
                            if (![vid isKindOfClass:[NSString class]] || !vid.length || [seen containsObject:vid]) continue;
                            [seen addObject:vid];
                            NSString *title = [vr respondsToSelector:@selector(title)] ? IVLCFFormattedString([vr performSelector:@selector(title)]) : @"";
                            NSString *artist = [vr respondsToSelector:@selector(shortBylineText)] ? IVLCFFormattedString([vr performSelector:@selector(shortBylineText)]) : @"";
                            if (!artist.length && [vr respondsToSelector:@selector(longBylineText)]) artist = IVLCFFormattedString([vr performSelector:@selector(longBylineText)]);
                            NSRange dot = [artist rangeOfString:@" • "];
                            if (dot.location != NSNotFound) artist = [artist substringToIndex:dot.location];
                            NSString *cover = @"";
                            if ([vr respondsToSelector:@selector(thumbnail)]) {
                                id td = [vr performSelector:@selector(thumbnail)];
                                if (td && [td respondsToSelector:@selector(thumbnailsArray)]) {
                                    id tarr = [td performSelector:@selector(thumbnailsArray)];
                                    if ([tarr isKindOfClass:[NSArray class]] && [(NSArray *)tarr count]) {
                                        id last = [(NSArray *)tarr lastObject];
                                        if ([last respondsToSelector:@selector(URL)]) {
                                            id u = [last performSelector:@selector(URL)];
                                            if ([u isKindOfClass:[NSString class]]) cover = IVLCFUpgradeCoverURL(u);
                                        }
                                    }
                                }
                            }
                            [direct addObject:@{ @"videoId": vid, @"title": title ?: @"", @"artist": artist ?: @"", @"artworkURL": cover ?: @"" }];
                        } @catch (__unused NSException *e) {}
                    }
                }
                if (direct.count >= 2 && outItems) {
                    *outItems = direct;
                    return;
                }
            }
            continue;
        }

        // Only walk ivars of YouTube / YTM classes
        if (![clsName hasPrefix:@"YT"] && ![clsName hasPrefix:@"YTM"] && ![clsName hasPrefix:@"ML"]) continue;

        Class c = [obj class];
        while (c && c != [NSObject class] && c != [UIViewController class] && c != [UIView class]) {
            NSString *cn = NSStringFromClass(c);
            if (![cn hasPrefix:@"YT"] && ![cn hasPrefix:@"YTM"] && ![cn hasPrefix:@"ML"]) break;
            unsigned int count = 0;
            Ivar *ivars = class_copyIvarList(c, &count);
            for (unsigned int i = 0; i < count; i++) {
                const char *enc = ivar_getTypeEncoding(ivars[i]);
                if (!enc || enc[0] != '@') continue;
                const char *name = ivar_getName(ivars[i]);
                if (!name) continue;
                NSString *nsName = [NSString stringWithUTF8String:name];
                // Prioritize queue / watch / panel / response / controller ivars
                NSString *ln = nsName.lowercaseString;
                BOOL interesting = [ln containsString:@"queue"] || [ln containsString:@"panel"] || [ln containsString:@"watch"]
                                || [ln containsString:@"playlist"] || [ln containsString:@"response"] || [ln containsString:@"content"]
                                || [ln containsString:@"renderer"] || [ln containsString:@"model"] || [ln containsString:@"data"]
                                || [ln containsString:@"controller"] || [ln containsString:@"player"] || [ln containsString:@"item"];
                if (!interesting) continue;
                @try {
                    id val = object_getIvar(obj, ivars[i]);
                    if (!val) continue;
                    if (outPlaylistID && !(*outPlaylistID).length && [ln containsString:@"playlistid"] && [val isKindOfClass:[NSString class]] && [val length]) {
                        *outPlaylistID = val;
                    } else {
                        [queue addObject:@[val, @(depth + 1)]];
                    }
                } @catch (__unused NSException *e) {}
            }
            free(ivars);
            c = class_getSuperclass(c);
        }
    }
}

#pragma mark - Queue loading

- (void)reloadQueue {
    IVLTrack *track = [IVLPlaybackManager shared].track;
    if (!track) {
        _items = @[];
        [self rebuildCards];
        return;
    }

    // 1. Live scan YTMWatchViewController / YTPlayerViewController for the real active queue
    UIViewController *player = [IVLPlaybackManager shared].player;
    UIViewController *watch = player.parentViewController ?: player;
    NSMutableArray<NSDictionary *> *scannedItems = nil;
    NSString *scannedPL = nil;
    if (watch) IVLCFScanForQueue(watch, &scannedItems, &scannedPL);
    if (!scannedItems.count && player && player != watch) IVLCFScanForQueue(player, &scannedItems, &scannedPL);
    if (scannedItems.count >= 2) {
        [IVLCoverFlowManager shared].capturedQueue = scannedItems;
    }
    if (scannedPL.length) {
        [IVLCoverFlowManager shared].capturedPlaylistID = scannedPL;
    }

    // 2. Prefer the real active queue captured from YouTube Music
    NSArray<NSDictionary *> *captured = [IVLCoverFlowManager shared].capturedQueue;
    if (captured.count) {
        NSString *vid = track.youtubeVideoID ?: @"";
        NSString *lt = track.title.lowercaseString ?: @"";
        BOOL containsCurrent = NO;
        for (NSDictionary *it in captured) {
            if ((vid.length && [vid isEqualToString:it[@"videoId"]]) ||
                (lt.length && [lt isEqualToString:[it[@"title"] lowercaseString]])) {
                containsCurrent = YES;
                break;
            }
        }
        if (containsCurrent) {
            [_spinner stopAnimating];
            _loadedVideoID = vid.length ? vid : track.videoID;
            _items = IVLRotateQueueForTrack(captured, track);
            _currentIndex = 0;
            [self rebuildCards];
            return;
        }
    }

    // Immediate card for current track
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

    // 3. Only query InnerTube `next` when we have a real playlistId (never fall back to unrelated RDAMVM radio)
    NSString *playlistID = [IVLCoverFlowManager shared].capturedPlaylistID;
    if (!playlistID.length) return;

    [_spinner startAnimating];
    NSString *reqID = track.youtubeVideoID ?: track.videoID;
    __weak typeof(self) weakSelf = self;
    [[IVLLyricsService shared] youtubeQueueForTrack:track playlistID:playlistID completion:^(NSArray<NSDictionary *> *items, NSInteger selIdx) {
        __strong typeof(weakSelf) ss = weakSelf;
        if (!ss) return;
        [ss->_spinner stopAnimating];
        if (!items.count) return;
        ss->_loadedVideoID = reqID;
        ss->_items = IVLRotateQueueForTrack(items, track);
        ss->_currentIndex = 0;
        [ss rebuildCards];
    }];
}

- (void)trackDidChange {
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

- (void)capturePlaylistPanel:(id)panel {
    static __thread BOOL inCapture = NO;
    if (inCapture || !panel) return;
    inCapture = YES;
    NSString *plID = nil;
    NSArray<NSDictionary *> *extracted = IVLCFExtractFromPanel(panel, &plID);
    inCapture = NO;
    if (!extracted.count) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.capturedQueue = extracted;
        if (plID.length) self.capturedPlaylistID = plID;
        if (self->_window && !self->_window.hidden) [self->_vc reloadQueue];
    });
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
