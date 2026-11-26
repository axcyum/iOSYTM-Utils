#import "IVLSettingsViewController.h"
#import "IVLSettings.h"
#import "IVLLocalization.h"
#import "IVLLyricsService.h"
#import "IVLLyricsService+Private.h"
#import "IVLTranslator.h"
#import "IVLSpotify.h"
#import "IVLDiscord.h"
#import "IVLWebNowPlaying.h"
#import "IVLExtras.h"
#import "IVLScrobbler.h"
#import "IVLRecognizer.h"
#import "IVLAudioDSP.h"

#ifndef IVL_VERSION
#define IVL_VERSION "1.1.1"
#endif

#ifndef IVL_COMMIT
#define IVL_COMMIT "dev"
#endif

static NSString *const kIVLAuthorURL    = @"https://github.com/axcyum";
static NSString *const kIVLRepoURL      = @"https://github.com/axcyum/iOSYTM-Utils";
static NSString *const kIVLActionsURL   = @"https://github.com/axcyum/iOSYTM-Utils/actions";
static NSString *const kIVLReleasesAPI  = @"https://api.github.com/repos/axcyum/iOSYTM-Utils/releases?per_page=10";
static NSString *const kIVLMainHeadAPI  = @"https://api.github.com/repos/axcyum/iOSYTM-Utils/commits/main";

static NSString *IVLNormalizeSemver(NSString *raw) {
    NSString *s = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if ([s hasPrefix:@"v"] || [s hasPrefix:@"V"]) s = [s substringFromIndex:1];
    NSRange dash = [s rangeOfString:@"-"];
    if (dash.location != NSNotFound) s = [s substringToIndex:dash.location];
    return s;
}

static NSComparisonResult IVLCompareSemver(NSString *a, NSString *b) {
    NSArray<NSString *> *pa = [IVLNormalizeSemver(a) componentsSeparatedByString:@"."];
    NSArray<NSString *> *pb = [IVLNormalizeSemver(b) componentsSeparatedByString:@"."];
    NSUInteger n = MAX(pa.count, pb.count);
    for (NSUInteger i = 0; i < n; i++) {
        NSInteger va = i < pa.count ? [pa[i] integerValue] : 0;
        NSInteger vb = i < pb.count ? [pb[i] integerValue] : 0;
        if (va < vb) return NSOrderedAscending;
        if (va > vb) return NSOrderedDescending;
    }
    return NSOrderedSame;
}

static BOOL IVLHasRealCommit(void) {
    NSString *c = @IVL_COMMIT;
    return c.length >= 7 && ![c isEqualToString:@"dev"] && ![c isEqualToString:@"unknown"];
}

static NSString *IVLDisplayVersion(void) {
    return IVLHasRealCommit() ? [NSString stringWithFormat:@"%s (%s)", IVL_VERSION, IVL_COMMIT] : @IVL_VERSION;
}

static UIImage *IVLBadgeImage(NSString *symbol, NSString *fallback, NSString *hex) {
    if (!symbol.length || !hex.length) return nil;
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    NSString *cacheKey = [NSString stringWithFormat:@"%@|%@|%@", symbol, fallback ?: @"", hex];
    UIImage *cached = [cache objectForKey:cacheKey];
    if (cached) return cached;

    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(28, 28)];
    UIImage *img = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *bg = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 28, 28) cornerRadius:7.0];
        [[IVLTheme colorFromHex:hex] setFill];
        [bg fill];

        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:13.5 weight:UIImageSymbolWeightSemibold];
        UIImage *sym = [UIImage systemImageNamed:symbol withConfiguration:cfg];
        if (!sym && fallback.length) sym = [UIImage systemImageNamed:fallback withConfiguration:cfg];
        if (!sym) sym = [UIImage systemImageNamed:@"gearshape.fill" withConfiguration:cfg];
        sym = [sym imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
        CGSize sz = sym.size;
        [sym drawInRect:CGRectMake((28.0 - sz.width) * 0.5, (28.0 - sz.height) * 0.5, sz.width, sz.height)];
    }];
    img = [img imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    if (img) [cache setObject:img forKey:cacheKey];
    return img;
}

typedef NS_ENUM(NSInteger, IVLRowType) {
    IVLRowSwitch,
    IVLRowSegment,   // rendered as a native iOS pull-down UIMenu button
    IVLRowStepper,
    IVLRowLink,
    IVLRowAction,
    IVLRowInfo,
    IVLRowText,
    IVLRowColor,
    IVLRowSlider,
    IVLRowPreview
};

@interface IVLRow : NSObject
@property (nonatomic) IVLRowType type;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSArray *options;
@property (nonatomic, copy) NSArray<NSNumber *> *values;
@property (nonatomic) double min, max, step;
@property (nonatomic, copy) NSString *(^format)(double v);
@property (nonatomic, copy) void (^onLive)(double v);
@property (nonatomic, copy) void (^action)(UIViewController *vc);
@property (nonatomic, copy) NSString *(^detail)(void);
@property (nonatomic, copy) BOOL (^getBool)(void);
@property (nonatomic, copy) void (^setBool)(BOOL on);
@property (nonatomic, assign) BOOL destructive;
@property (nonatomic, assign) BOOL disabled;
@property (nonatomic, assign) BOOL external;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, copy) NSString *symbol;
@property (nonatomic, copy) NSString *fallbackSymbol;
@property (nonatomic, copy) NSString *badgeHex;
@property (nonatomic, copy) NSString *placeholder;
@property (nonatomic) UIKeyboardType keyboard;
@property (nonatomic) double danger;
@property (nonatomic) BOOL secure;
@property (nonatomic, copy) void (^onText)(NSString *text);
@end

@implementation IVLRow
+ (instancetype)type:(IVLRowType)t key:(NSString *)k title:(NSString *)title {
    IVLRow *r = [self new];
    r.type = t;
    r.key = k;
    r.title = title;
    return r;
}
- (instancetype)withBadge:(NSString *)symbol fallback:(NSString *)fb hex:(NSString *)hex {
    self.symbol = symbol;
    self.fallbackSymbol = fb;
    self.badgeHex = hex;
    return self;
}
@end

@interface IVLSection : NSObject
@property (nonatomic, copy) NSString *title, *footer;
@property (nonatomic, copy) NSArray<IVLRow *> *rows;
@end

@implementation IVLSection
+ (instancetype)title:(NSString *)t footer:(NSString *)f rows:(NSArray *)rows {
    IVLSection *s = [self new];
    s.title = t;
    s.footer = f;
    s.rows = rows;
    return s;
}
@end

@implementation IVLSettingsViewController {
    NSArray<IVLSection *> *_sections;
    NSString *_page;
    __weak UILabel *_previewLabel;
    BOOL _checkingUpdate;
    NSString *_updateStatus;
}

- (instancetype)init { return [self initWithPage:nil]; }

- (instancetype)initWithPage:(NSString *)page {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _page = [page copy];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    NSDictionary<NSString *, NSString *> *titles = @{
        @"button": IVLLoc(@"sec_button"),
        @"appearance": IVLLoc(@"sec_appearance"),
        @"extras": IVLLoc(@"sec_appearance"),
        @"display": IVLLoc(@"sec_display"),
        @"translation": IVLLoc(@"sec_translation"),
        @"sync": IVLLoc(@"sec_sync"),
        @"lock": IVLLoc(@"sec_lock"),
        @"spotify": @"Spotify",
        @"github_lrc": IVLLoc(@"github_lrc_repo"),
        @"audio": IVLLoc(@"sec_audio"),
        @"discord": @"Discord Rich Presence",
        @"wnp": @"WebNowPlaying",
        @"accent": IVLLoc(@"accent_color"),
        @"bgcolor": IVLLoc(@"bg_color"),
        @"scrobble": IVLLoc(@"scrobble"),
    };
    self.title = _page ? (titles[_page] ?: @"iOS YTMusic Utilities") : @"iOS YTMusic Utilities";
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    if (!_page) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    }
    [self buildSections];
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(rebuild) name:IVLSpotifyStateDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(rebuild) name:IVLDiscordStatusDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(rebuild) name:IVLWebNowPlayingStatusDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(rebuild) name:IVLSleepTimerDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(rebuild) name:IVLScrobblerDidChangeNotification object:nil];
}

- (void)rebuild {
    [self buildSections];
    [self.tableView reloadData];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self rebuild];
}

- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }

extern void IVLScrobblerSetSecret(NSString *account, NSString *value);

#pragma mark - Subpages

- (NSArray<IVLSection *> *)buttonSections {
    IVLRow *(^sw)(NSString *, NSString *) = ^(NSString *k, NSString *t) { return [IVLRow type:IVLRowSwitch key:k title:t]; };
    return @[
        [IVLSection title:nil footer:IVLLoc(@"footer_general") rows:@[
            sw(IVLKeyShowButton, IVLLoc(@"show_button")),
            sw(IVLKeyMiniLyric, IVLLoc(@"mini_lyric")),
            sw(IVLKeyHomeBarLyrics, IVLLoc(@"home_bar_lyrics")),
        ]],
    ];
}

- (NSArray<IVLSection *> *)appearanceSections {
    IVLRow *theme = [IVLRow type:IVLRowSegment key:IVLKeyBackground title:IVLLoc(@"theme")];
    theme.options = @[IVLLoc(@"bg_artwork"), IVLLoc(@"bg_solid"), IVLLoc(@"bg_dynamic"), IVLLoc(@"bg_black")];

    IVLRow *(^colorPage)(NSString *, NSString *, NSString *) = ^(NSString *pageID, NSString *title, NSString *key) {
        IVLRow *r = [IVLRow type:IVLRowLink key:@"" title:title];
        r.detail = ^NSString *{
            NSString *hex = [IVLSettings objectForKey:key];
            return hex.length ? [@"#" stringByAppendingString:hex] : IVLLoc(@"color_default");
        };
        r.action = ^(UIViewController *vc) { [vc.navigationController pushViewController:[[IVLSettingsViewController alloc] initWithPage:pageID] animated:YES]; };
        return r;
    };
    IVLRow *accent = colorPage(@"accent", IVLLoc(@"accent_color"), IVLKeyAccentColor);
    IVLRow *bg = colorPage(@"bgcolor", IVLLoc(@"bg_color"), IVLKeyBackgroundColor);
    IVLRow *openPlayer = [IVLRow type:IVLRowSwitch key:IVLKeyOpenPlayer title:IVLLoc(@"open_player")];

    __weak typeof(self) weakSelf = self;
    BOOL amUIOn = [IVLSettings boolForKey:IVLKeyImmersivePlayer];

    IVLRow *immersive = [IVLRow type:IVLRowSwitch key:IVLKeyImmersivePlayer title:IVLLoc(@"immersive_player")];
    immersive.getBool = ^BOOL { return [IVLSettings boolForKey:IVLKeyImmersivePlayer]; };
    immersive.setBool = ^(BOOL on) {
        [IVLSettings setBool:on forKey:IVLKeyImmersivePlayer];
        if (on) [IVLSettings setBool:YES forKey:IVLKeyAMLyrics];
        [weakSelf rebuild];
    };

    IVLRow *amLyrics = [IVLRow type:IVLRowSwitch key:IVLKeyAMLyrics title:IVLLoc(@"am_lyrics")];
    amLyrics.disabled = amUIOn;
    amLyrics.getBool = ^BOOL {
        return [IVLSettings boolForKey:IVLKeyImmersivePlayer] ? YES : [IVLSettings boolForKey:IVLKeyAMLyrics];
    };

    IVLRow *coverFlow = [IVLRow type:IVLRowSwitch key:IVLKeyCoverFlow title:IVLLoc(@"cover_flow")];

    return @[
        [IVLSection title:IVLLoc(@"theme") footer:IVLLoc(@"footer_theme") rows:@[theme, accent, bg]],
        [IVLSection title:IVLLoc(@"player_style") footer:IVLLoc(@"footer_player_style") rows:@[openPlayer, amLyrics, immersive, coverFlow]],
    ];
}

- (NSArray<IVLSection *> *)displaySections {
    IVLRow *(^sw)(NSString *, NSString *) = ^(NSString *k, NSString *t) { return [IVLRow type:IVLRowSwitch key:k title:t]; };
    IVLRow *preview = [IVLRow type:IVLRowPreview key:@"" title:@""];

    __weak typeof(self) weakSelf = self;
    IVLRow *size = [IVLRow type:IVLRowSlider key:IVLKeyFontSize title:IVLLoc(@"text_size")];
    size.min = 16; size.max = 52; size.step = 1;
    size.format = ^NSString *(double v) { return [NSString stringWithFormat:@"%.0f pt", v]; };
    size.onLive = ^(double v) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf && strongSelf->_previewLabel) {
            strongSelf->_previewLabel.font = [UIFont systemFontOfSize:v weight:UIFontWeightBold];
        }
    };

    IVLRow *align = [IVLRow type:IVLRowSegment key:IVLKeyAlignment title:IVLLoc(@"alignment")];
    align.options = @[IVLLoc(@"align_left"), IVLLoc(@"align_center")];

    return @[
        [IVLSection title:nil footer:nil rows:@[preview, size, align]],
        [IVLSection title:nil footer:IVLLoc(@"footer_display") rows:@[
            sw(IVLKeyKaraoke, IVLLoc(@"karaoke")),
            sw(IVLKeyShowBreaks, IVLLoc(@"show_breaks")),
            sw(IVLKeyKeepAwake, IVLLoc(@"keep_awake")),
        ]],
    ];
}

- (NSArray<IVLSection *> *)translationSections {
    IVLRow *tr = [IVLRow type:IVLRowSwitch key:IVLKeyTranslation title:IVLLoc(@"translation")];
    IVLRow *lang = [IVLRow type:IVLRowLink key:IVLKeyTranslationLang title:IVLLoc(@"translation_lang")];
    lang.detail = ^NSString *{ return [IVLLanguagePickerViewController nameForCode:[IVLSettings objectForKey:IVLKeyTranslationLang]]; };
    lang.action = ^(UIViewController *vc) { [vc.navigationController pushViewController:[IVLLanguagePickerViewController new] animated:YES]; };

    IVLRow *pron = [IVLRow type:IVLRowSegment key:IVLKeyPronunciation title:IVLLoc(@"pronunciation")];
    pron.options = @[IVLLoc(@"off"), IVLLoc(@"romaji"), IVLLoc(@"kana")];
    return @[
        [IVLSection title:nil footer:IVLLoc(@"footer_translation") rows:@[tr, lang, pron]],
    ];
}

- (NSArray<IVLSection *> *)syncSections {
    IVLRow *offset = [IVLRow type:IVLRowStepper key:IVLKeyGlobalOffset title:IVLLoc(@"global_offset")];
    offset.min = -3000; offset.max = 3000; offset.step = 50;
    offset.format = ^NSString *(double v) { return [NSString stringWithFormat:@"%+.2fs", v / 1000.0]; };

    __weak typeof(self) weakSelf = self;
    IVLRow *reset = [IVLRow type:IVLRowAction key:@"" title:IVLLoc(@"reset_offset")];
    reset.action = ^(UIViewController *vc) {
        [IVLSettings setObject:@0 forKey:IVLKeyGlobalOffset];
        [weakSelf rebuild];
    };

    IVLRow *resume = [IVLRow type:IVLRowSegment key:IVLKeyAutoResume title:IVLLoc(@"auto_resume")];
    resume.options = @[IVLLoc(@"off"), @"3s", @"5s", @"10s"];
    resume.values = @[@0, @3, @5, @10];
    return @[
        [IVLSection title:nil footer:IVLLoc(@"footer_sync") rows:@[offset, reset]],
        [IVLSection title:nil footer:nil rows:@[resume]],
    ];
}

- (NSArray<IVLSection *> *)scrobbleSections {
    IVLScrobbler *sc = [IVLScrobbler shared];
    IVLRow *(^sw)(NSString *, NSString *) = ^(NSString *k, NSString *t) { return [IVLRow type:IVLRowSwitch key:k title:t]; };
    IVLRow *lfState = [IVLRow type:IVLRowInfo key:@"" title:IVLLoc(@"status")];
    lfState.detail = ^NSString *{ return [IVLScrobbler shared].lastfmStatus; };
    IVLRow *key = [IVLRow type:IVLRowText key:IVLKeyLastfmKey title:IVLLoc(@"lastfm_key")];
    key.placeholder = @"API key";
    key.keyboard = UIKeyboardTypeASCIICapable;
    IVLRow *secret = [IVLRow type:IVLRowText key:@"" title:IVLLoc(@"lastfm_secret")];
    secret.placeholder = IVLLoc(@"secret_placeholder");
    secret.secure = YES;
    secret.onText = ^(NSString *t) { if (t.length) IVLScrobblerSetSecret(@"lastfm-secret", t); };
    __block NSString *user = nil, *pass = nil;
    IVLRow *u = [IVLRow type:IVLRowText key:@"" title:IVLLoc(@"lastfm_user")];
    u.placeholder = [IVLSettings objectForKey:IVLKeyLastfmUser] ?: @"";
    u.keyboard = UIKeyboardTypeASCIICapable;
    u.onText = ^(NSString *t) { user = t; };
    IVLRow *pw = [IVLRow type:IVLRowText key:@"" title:IVLLoc(@"lastfm_password")];
    pw.placeholder = @"••••••";
    pw.secure = YES;
    pw.onText = ^(NSString *t) { pass = t; };
    IVLRow *login = [IVLRow type:IVLRowAction key:@"" title:sc.lastfmLoggedIn ? IVLLoc(@"lastfm_relogin") : IVLLoc(@"lastfm_login")];
    login.action = ^(UIViewController *vc) {
        [vc.view endEditing:YES];
        [[IVLScrobbler shared] lastfmLoginWithUser:user ?: @"" password:pass ?: @"" completion:^(BOOL ok, NSString *msg) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:ok ? @"Last.fm" : IVLLoc(@"lastfm_login_failed") message:msg preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [vc presentViewController:a animated:YES completion:nil];
        }];
    };
    IVLRow *logout = [IVLRow type:IVLRowAction key:@"" title:IVLLoc(@"spotify_logout")];
    logout.destructive = YES;
    logout.action = ^(UIViewController *vc) { [[IVLScrobbler shared] lastfmLogout]; };
    NSMutableArray *lfRows = [NSMutableArray arrayWithObjects:sw(IVLKeyLastfmEnabled, IVLLoc(@"lastfm_enabled")), lfState, key, secret, u, pw, login, nil];
    if (sc.lastfmLoggedIn) [lfRows addObject:logout];

    IVLRow *lbState = [IVLRow type:IVLRowInfo key:@"" title:IVLLoc(@"status")];
    lbState.detail = ^NSString *{ return [IVLScrobbler shared].listenbrainzStatus; };
    IVLRow *token = [IVLRow type:IVLRowText key:@"" title:IVLLoc(@"lb_token")];
    token.placeholder = IVLLoc(@"secret_placeholder");
    token.secure = YES;
    token.onText = ^(NSString *t) {
        if (!t.length) return;
        IVLScrobblerSetSecret(@"listenbrainz", t);
        [[IVLScrobbler shared] verifyListenBrainz:^(BOOL ok, NSString *m) {}];
    };
    IVLRow *pending = [IVLRow type:IVLRowInfo key:@"" title:IVLLoc(@"scrobble_pending")];
    pending.detail = ^NSString *{ return @([IVLScrobbler shared].pending).stringValue; };
    return @[
        [IVLSection title:@"Last.fm" footer:IVLLoc(@"footer_lastfm") rows:lfRows],
        [IVLSection title:@"ListenBrainz" footer:IVLLoc(@"footer_listenbrainz") rows:@[sw(IVLKeyListenBrainzEnabled, IVLLoc(@"lb_enabled")), lbState, token]],
        [IVLSection title:nil footer:IVLLoc(@"footer_scrobble") rows:@[pending]],
    ];
}

- (NSArray<IVLSection *> *)wnpSections {
    IVLRow *(^sw)(NSString *, NSString *) = ^(NSString *k, NSString *t) { return [IVLRow type:IVLRowSwitch key:k title:t]; };
    IVLRow *state = [IVLRow type:IVLRowInfo key:@"" title:IVLLoc(@"status")];
    state.detail = ^NSString *{ return [IVLWebNowPlaying shared].status; };
    IVLRow *host = [IVLRow type:IVLRowText key:IVLKeyWNPHost title:IVLLoc(@"wnp_host")];
    host.placeholder = @"192.168.1.10";
    host.keyboard = UIKeyboardTypeURL;
    IVLRow *port = [IVLRow type:IVLRowText key:IVLKeyWNPPort title:IVLLoc(@"wnp_port")];
    port.placeholder = @"8974";
    port.keyboard = UIKeyboardTypeNumberPad;
    IVLRow *retry = [IVLRow type:IVLRowAction key:@"" title:IVLLoc(@"wnp_reconnect")];
    retry.action = ^(UIViewController *vc) { [[IVLWebNowPlaying shared] reconnect]; };
    return @[
        [IVLSection title:nil footer:IVLLoc(@"footer_wnp") rows:@[sw(IVLKeyWNPEnabled, IVLLoc(@"wnp_enabled")), state]],
        [IVLSection title:IVLLoc(@"wnp_adapter") footer:IVLLoc(@"footer_wnp_adapter") rows:@[host, port, retry]],
        [IVLSection title:IVLLoc(@"wnp_control_title") footer:IVLLoc(@"footer_wnp_control") rows:@[sw(IVLKeyWNPControl, IVLLoc(@"wnp_control"))]],
    ];
}

- (NSArray<IVLSection *> *)colorSectionsForKey:(NSString *)key includeDefault:(NSString *)defaultTitle {
    NSMutableArray *rows = [NSMutableArray array];
    IVLRow *def = [IVLRow type:IVLRowColor key:key title:defaultTitle];
    def.placeholder = @"";
    [rows addObject:def];
    for (NSArray *c in [IVLTheme presetColors]) {
        IVLRow *r = [IVLRow type:IVLRowColor key:key title:c[0]];
        r.placeholder = c[1];
        [rows addObject:r];
    }
    IVLRow *custom = [IVLRow type:IVLRowText key:key title:IVLLoc(@"color_hex")];
    custom.placeholder = @"FF7EB6";
    custom.keyboard = UIKeyboardTypeASCIICapable;
    return @[[IVLSection title:nil footer:nil rows:rows], [IVLSection title:nil footer:IVLLoc(@"footer_color_hex") rows:@[custom]]];
}

- (NSArray<IVLSection *> *)lockSections {
    IVLRow *(^sw)(NSString *, NSString *) = ^(NSString *k, NSString *t) { return [IVLRow type:IVLRowSwitch key:k title:t]; };
    IVLRow *lead = [IVLRow type:IVLRowStepper key:IVLKeyLockLead title:IVLLoc(@"lock_lead")];
    lead.min = 0; lead.max = 1000; lead.step = 50;
    lead.format = ^NSString *(double v) { return [NSString stringWithFormat:@"%.2fs", v / 1000.0]; };
    return @[
        [IVLSection title:nil footer:IVLLoc(@"footer_lock") rows:@[sw(IVLKeyLockEnabled, IVLLoc(@"lock_enabled"))]],
        [IVLSection title:IVLLoc(@"sec_display") footer:IVLLoc(@"footer_lock_lead") rows:@[
            sw(IVLKeyLockAnimation, IVLLoc(@"lock_animation")),
            sw(IVLKeyLockKaraoke, IVLLoc(@"lock_karaoke")),
            sw(IVLKeyLockTranslation, IVLLoc(@"lock_translation")),
            lead,
        ]],
    ];
}

- (NSArray<IVLSection *> *)spotifySections {
    IVLSpotify *sp = [IVLSpotify shared];
    IVLRow *state = [IVLRow type:IVLRowInfo key:@"" title:IVLLoc(@"status")];
    state.detail = ^NSString *{ return [IVLSpotify shared].statusText; };
    IVLRow *login = [IVLRow type:IVLRowAction key:@"" title:sp.loggedIn ? IVLLoc(@"spotify_relogin") : IVLLoc(@"spotify_login")];
    login.action = ^(UIViewController *vc) { [vc presentViewController:[[IVLSpotify shared] loginViewController] animated:YES completion:nil]; };
    IVLRow *logout = [IVLRow type:IVLRowAction key:@"" title:IVLLoc(@"spotify_logout")];
    logout.destructive = YES;
    logout.action = ^(UIViewController *vc) { [[IVLSpotify shared] logout]; };
    IVLRow *use = [IVLRow type:IVLRowSwitch key:IVLKeyProviderSpotify title:IVLLoc(@"spotify_use")];
    NSMutableArray *rows = [NSMutableArray arrayWithObjects:state, login, nil];
    if (sp.loggedIn) [rows addObject:logout];
    return @[
        [IVLSection title:nil footer:IVLLoc(@"footer_spotify") rows:rows],
        [IVLSection title:nil footer:nil rows:@[use]],
    ];
}

- (NSArray<IVLSection *> *)githubLRCSections {
    IVLRow *use = [IVLRow type:IVLRowSwitch key:IVLKeyProviderGitHub title:IVLLoc(@"github_lrc_use")];

    IVLRow *repo = [IVLRow type:IVLRowText key:IVLKeyGitHubLRCRepo title:IVLLoc(@"github_lrc_repo_field")];
    repo.placeholder = @"owner/repo";
    repo.keyboard = UIKeyboardTypeURL;
    repo.onText = ^(NSString *t) {
        NSString *extractedBranch = nil;
        NSString *norm = [IVLLyricsService parseGitHubOwnerRepo:t extractedBranch:&extractedBranch];
        [IVLSettings setObject:(norm.length ? norm : t) forKey:IVLKeyGitHubLRCRepo];
        if (extractedBranch.length && ![[IVLSettings objectForKey:IVLKeyGitHubLRCBranch] length]) {
            [IVLSettings setObject:extractedBranch forKey:IVLKeyGitHubLRCBranch];
        }
        [[IVLLyricsService shared] invalidateGitHubLRCCache];
    };

    IVLRow *branch = [IVLRow type:IVLRowText key:IVLKeyGitHubLRCBranch title:IVLLoc(@"github_lrc_branch")];
    branch.placeholder = IVLLoc(@"github_lrc_branch_placeholder");
    branch.keyboard = UIKeyboardTypeASCIICapable;
    branch.onText = ^(NSString *t) {
        [IVLSettings setObject:t forKey:IVLKeyGitHubLRCBranch];
        [[IVLLyricsService shared] invalidateGitHubLRCCache];
    };

    __weak typeof(self) weakSelf = self;
    IVLRow *test = [IVLRow type:IVLRowAction key:@"" title:IVLLoc(@"github_lrc_test")];
    test.action = ^(UIViewController *vc) {
        [vc.view endEditing:YES];
        NSString *r = [IVLSettings objectForKey:IVLKeyGitHubLRCRepo] ?: @"";
        NSString *b = [IVLSettings objectForKey:IVLKeyGitHubLRCBranch] ?: @"";
        [[IVLLyricsService shared] verifyGitHubLRCRepo:r branch:b completion:^(BOOL ok, NSUInteger count, NSString *norm, NSString *errMsg) {
            if (ok && norm.length) {
                [IVLSettings setObject:norm forKey:IVLKeyGitHubLRCRepo];
                [weakSelf rebuild];
            }
            NSString *title = ok ? IVLLoc(@"github_lrc_test_ok") : IVLLoc(@"github_lrc_test_fail");
            NSString *msg = ok ? [NSString stringWithFormat:IVLLoc(@"github_lrc_test_ok_fmt"), norm ?: r, (unsigned long)count] : (errMsg ?: @"Error");
            UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [vc presentViewController:a animated:YES completion:nil];
        }];
    };

    return @[
        [IVLSection title:nil footer:IVLLoc(@"footer_github_lrc") rows:@[repo, branch, test]],
        [IVLSection title:nil footer:nil rows:@[use]],
    ];
}

- (NSArray<IVLSection *> *)audioSections {
    IVLRow *kOn = [IVLRow type:IVLRowSwitch key:IVLKeyKaraokeMode title:IVLLoc(@"karaoke_mode")];
    IVLRow *kStr = [IVLRow type:IVLRowSlider key:IVLKeyKaraokeStrength title:IVLLoc(@"karaoke_strength")];
    kStr.min = 0; kStr.max = 100; kStr.step = 5;
    kStr.format = ^NSString *(double v) { return [NSString stringWithFormat:@"%.0f%%", v]; };

    IVLRow *bOn = [IVLRow type:IVLRowSwitch key:IVLKeyVolumeBoost title:IVLLoc(@"volume_boost")];
    IVLRow *bLvl = [IVLRow type:IVLRowSlider key:IVLKeyVolumeBoostLevel title:IVLLoc(@"volume_boost_level")];
    bLvl.min = 100; bLvl.max = 250; bLvl.step = 10;
    bLvl.format = ^NSString *(double v) { return [NSString stringWithFormat:@"%.0f%%", v]; };

    IVLRow *st = [IVLRow type:IVLRowInfo key:@"" title:IVLLoc(@"status")];
    st.detail = ^NSString *{ return [IVLAudioDSP statusText]; };

    return @[
        [IVLSection title:IVLLoc(@"karaoke_mode") footer:IVLLoc(@"footer_karaoke_mode") rows:@[kOn, kStr]],
        [IVLSection title:IVLLoc(@"volume_boost") footer:IVLLoc(@"footer_volume_boost") rows:@[bOn, bLvl]],
        [IVLSection title:nil footer:nil rows:@[st]],
    ];
}

- (NSArray<IVLSection *> *)discordSections {
    IVLDiscord *d = [IVLDiscord shared];
    IVLRow *state = [IVLRow type:IVLRowInfo key:@"" title:IVLLoc(@"status")];
    state.detail = ^NSString *{ return [IVLDiscord shared].status; };
    if (![IVLDiscord available]) {
        return @[[IVLSection title:nil footer:IVLLoc(@"footer_discord_unavailable") rows:@[state]]];
    }
    IVLRow *login = [IVLRow type:IVLRowAction key:@"" title:d.linked ? IVLLoc(@"discord_relink") : IVLLoc(@"discord_link")];
    login.action = ^(UIViewController *vc) { [[IVLDiscord shared] login]; };
    IVLRow *share = [IVLRow type:IVLRowSwitch key:@"" title:IVLLoc(@"discord_share")];
    share.getBool = ^BOOL { return [[IVLDiscord shared] enabled]; };
    share.setBool = ^(BOOL on) { on ? [[IVLDiscord shared] retry] : [[IVLDiscord shared] disable]; };
    IVLRow *cover = [IVLRow type:IVLRowSwitch key:@"" title:IVLLoc(@"discord_cover")];
    cover.getBool = ^BOOL { return [[IVLDiscord shared] coverEnabled]; };
    cover.setBool = ^(BOOL on) { [[IVLDiscord shared] setCoverEnabled:on]; };
    IVLRow *logs = [IVLRow type:IVLRowAction key:@"" title:IVLLoc(@"discord_logs")];
    logs.action = ^(UIViewController *vc) {
        NSArray *files = [[IVLDiscord shared] logFiles];
        if (!files.count) return;
        UIActivityViewController *act = [[UIActivityViewController alloc] initWithActivityItems:files applicationActivities:nil];
        act.popoverPresentationController.sourceView = vc.view;
        [vc presentViewController:act animated:YES completion:nil];
    };
    IVLRow *forget = [IVLRow type:IVLRowAction key:@"" title:IVLLoc(@"discord_forget")];
    forget.destructive = YES;
    forget.action = ^(UIViewController *vc) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:IVLLoc(@"discord_forget") message:IVLLoc(@"discord_forget_confirm") preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:IVLLoc(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:IVLLoc(@"discord_forget") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { [[IVLDiscord shared] forget]; }]];
        [vc presentViewController:a animated:YES completion:nil];
    };
    NSMutableArray *account = [NSMutableArray arrayWithObjects:state, login, nil];
    if (d.linked) [account addObject:forget];
    IVLRow *interval = [IVLRow type:IVLRowSlider key:IVLKeyDiscordInterval title:IVLLoc(@"discord_interval")];
    interval.min = 3; interval.max = 60; interval.step = 1; interval.danger = 15;
    interval.format = ^NSString *(double v) {
        return v < 15 ? [NSString stringWithFormat:IVLLoc(@"discord_interval_danger_fmt"), v] : [NSString stringWithFormat:IVLLoc(@"discord_interval_fmt"), v];
    };
    IVLRow *statusDisp = [IVLRow type:IVLRowSegment key:IVLKeyDiscordStatusDisplay title:IVLLoc(@"discord_status_display")];
    statusDisp.options = @[IVLLoc(@"status_disp_name"), IVLLoc(@"status_disp_artist"), IVLLoc(@"status_disp_title")];
    IVLRow *songButton = [IVLRow type:IVLRowSwitch key:IVLKeyDiscordSongButton title:IVLLoc(@"discord_song_button")];
    IVLRow *githubButton = [IVLRow type:IVLRowSwitch key:IVLKeyDiscordGitHubButton title:IVLLoc(@"discord_github_button")];
    return @[
        [IVLSection title:nil footer:IVLLoc(@"footer_discord") rows:account],
        [IVLSection title:nil footer:nil rows:@[share, cover]],
        [IVLSection title:IVLLoc(@"discord_display") footer:IVLLoc(@"footer_discord_display") rows:@[statusDisp, songButton, githubButton]],
        [IVLSection title:IVLLoc(@"discord_interval") footer:IVLLoc(@"footer_discord_interval") rows:@[interval]],
        [IVLSection title:nil footer:nil rows:@[logs]],
    ];
}

#pragma mark - Root 5-Section Layout

- (void)buildSections {
    if ([_page isEqualToString:@"button"]) { _sections = [self buttonSections]; return; }
    if ([_page isEqualToString:@"appearance"] || [_page isEqualToString:@"extras"]) { _sections = [self appearanceSections]; return; }
    if ([_page isEqualToString:@"display"]) { _sections = [self displaySections]; return; }
    if ([_page isEqualToString:@"translation"]) { _sections = [self translationSections]; return; }
    if ([_page isEqualToString:@"sync"]) { _sections = [self syncSections]; return; }
    if ([_page isEqualToString:@"lock"]) { _sections = [self lockSections]; return; }
    if ([_page isEqualToString:@"spotify"]) { _sections = [self spotifySections]; return; }
    if ([_page isEqualToString:@"github_lrc"]) { _sections = [self githubLRCSections]; return; }
    if ([_page isEqualToString:@"audio"]) { _sections = [self audioSections]; return; }
    if ([_page isEqualToString:@"discord"]) { _sections = [self discordSections]; return; }
    if ([_page isEqualToString:@"wnp"]) { _sections = [self wnpSections]; return; }
    if ([_page isEqualToString:@"scrobble"]) { _sections = [self scrobbleSections]; return; }
    if ([_page isEqualToString:@"accent"]) { _sections = [self colorSectionsForKey:IVLKeyAccentColor includeDefault:IVLLoc(@"color_default")]; return; }
    if ([_page isEqualToString:@"bgcolor"]) { _sections = [self colorSectionsForKey:IVLKeyBackgroundColor includeDefault:IVLLoc(@"color_default")]; return; }

    IVLRow *(^subpage)(NSString *, NSString *, NSString *, NSString *, NSString *, NSString *(^)(void)) =
    ^(NSString *pageID, NSString *title, NSString *sym, NSString *fb, NSString *hex, NSString *(^detail)(void)) {
        IVLRow *r = [[IVLRow type:IVLRowLink key:@"" title:title] withBadge:sym fallback:fb hex:hex];
        r.detail = detail;
        r.action = ^(UIViewController *vc) {
            [vc.navigationController pushViewController:[[IVLSettingsViewController alloc] initWithPage:pageID] animated:YES];
        };
        return r;
    };

    // 1. ivLyrics (Compatible) — Master switch, Floating button, Appearance, Lyrics style
    IVLRow *master = [[IVLRow type:IVLRowSwitch key:IVLKeyEnabled title:IVLLoc(@"enabled")]
                      withBadge:@"music.quarternote.3" fallback:@"music.note" hex:@"FF2D55"];

    IVLRow *btnPage = subpage(@"button", IVLLoc(@"floating_button"), @"pip.fill", @"rectangle.on.rectangle", @"FF6B4A", ^NSString *{
        if (![IVLSettings boolForKey:IVLKeyShowButton]) return IVLLoc(@"off");
        return [IVLSettings boolForKey:IVLKeyMiniLyric] ? IVLLoc(@"mini_lyric_short") : IVLLoc(@"on");
    });

    IVLRow *appearancePage = subpage(@"appearance", IVLLoc(@"sec_appearance"), @"paintbrush.fill", @"paintpalette.fill", @"AF52DE", ^NSString *{
        NSArray *themes = @[IVLLoc(@"bg_artwork"), IVLLoc(@"bg_solid"), IVLLoc(@"bg_dynamic"), IVLLoc(@"bg_black")];
        NSInteger idx = [IVLSettings integerForKey:IVLKeyBackground];
        return (idx >= 0 && idx < (NSInteger)themes.count) ? themes[idx] : themes[0];
    });

    IVLRow *displayPage = subpage(@"display", IVLLoc(@"sec_display"), @"textformat.size", @"textformat", @"FF9F0A", ^NSString *{
        return [NSString stringWithFormat:@"%.0f pt", [IVLSettings doubleForKey:IVLKeyFontSize]];
    });

    // 2. Lyrics & Language — Sources (with Spotify & Captions inside), Translation/Pronunciation, Sync
    IVLRow *sourcesPage = [[IVLRow type:IVLRowLink key:IVLKeyProviderOrder title:IVLLoc(@"sec_sources")]
                           withBadge:@"globe" fallback:@"network" hex:@"0A84FF"];
    sourcesPage.detail = ^NSString *{
        NSArray<NSString *> *enabled = [IVLSettings enabledProviderIDs];
        if (!enabled.count) return IVLLoc(@"off");
        NSString *first = [IVLSettings nameForProvider:enabled.firstObject];
        if (enabled.count == 1) return first;
        return [NSString stringWithFormat:IVLLoc(@"sources_more_fmt"), first, (unsigned long)(enabled.count - 1)];
    };
    sourcesPage.action = ^(UIViewController *vc) {
        [vc.navigationController pushViewController:[IVLProvidersViewController new] animated:YES];
    };

    IVLRow *transPage = subpage(@"translation", IVLLoc(@"sec_translation"), @"character.bubble.fill", @"bubble.left.fill", @"32ADE6", ^NSString *{
        BOOL trOn = [IVLSettings boolForKey:IVLKeyTranslation];
        NSInteger pr = [IVLSettings integerForKey:IVLKeyPronunciation];
        NSArray *prNames = @[IVLLoc(@"off"), IVLLoc(@"romaji"), IVLLoc(@"kana")];
        NSString *prText = (pr > 0 && pr < (NSInteger)prNames.count) ? prNames[pr] : nil;
        NSString *trText = trOn ? [IVLLanguagePickerViewController nameForCode:[IVLSettings objectForKey:IVLKeyTranslationLang]] : nil;
        if (trText && prText) return [NSString stringWithFormat:@"%@ · %@", trText, prText];
        return trText ?: prText ?: IVLLoc(@"off");
    });

    IVLRow *syncPage = subpage(@"sync", IVLLoc(@"sec_sync"), @"metronome.fill", @"timer", @"30D158", ^NSString *{
        double ms = [IVLSettings doubleForKey:IVLKeyGlobalOffset];
        NSInteger res = [IVLSettings integerForKey:IVLKeyAutoResume];
        NSString *offStr = [NSString stringWithFormat:@"%+.2fs", ms / 1000.0];
        return res > 0 ? [NSString stringWithFormat:@"%@ · %lds", offStr, (long)res] : offStr;
    });

    // 3. Tools — Lock Screen Lyrics, External Display, Audio DSP, Sleep Timer, Song Recognition (ShazamKit)
    IVLRow *lockPage = subpage(@"lock", IVLLoc(@"sec_lock"), @"lock.iphone", @"lock.fill", @"5E5CE6", ^NSString *{
        return IVLLoc([IVLSettings boolForKey:IVLKeyLockEnabled] ? @"on" : @"off");
    });

    IVLRow *extDisplay = [[IVLRow type:IVLRowSwitch key:IVLKeyExternalDisplay title:IVLLoc(@"external_display")]
                          withBadge:@"airplayvideo" fallback:@"tv.fill" hex:@"32ADE6"];

    IVLRow *audioPage = subpage(@"audio", IVLLoc(@"sec_audio"), @"waveform.path.ecg", @"speaker.wave.3.fill", @"FF375F", ^NSString *{
        BOOL k = [IVLSettings boolForKey:IVLKeyKaraokeMode];
        BOOL b = [IVLSettings boolForKey:IVLKeyVolumeBoost];
        if (k && b) return [NSString stringWithFormat:@"%@ · %.0f%%", IVLLoc(@"karaoke_short"), [IVLSettings doubleForKey:IVLKeyVolumeBoostLevel]];
        if (k) return IVLLoc(@"karaoke_short");
        if (b) return [NSString stringWithFormat:@"%.0f%%", [IVLSettings doubleForKey:IVLKeyVolumeBoostLevel]];
        return IVLLoc(@"off");
    });

    IVLRow *sleepPage = [[IVLRow type:IVLRowLink key:@"" title:IVLLoc(@"sleep_timer")]
                         withBadge:@"moon.zzz.fill" fallback:@"moon.fill" hex:@"BF5AF2"];
    sleepPage.detail = ^NSString *{ return [[IVLSleepTimer shared] statusText]; };
    sleepPage.action = ^(UIViewController *vc) {
        [vc.navigationController pushViewController:[IVLSleepTimerViewController new] animated:YES];
    };

    IVLRow *recognizeRow = [[IVLRow type:IVLRowLink key:@"" title:IVLLoc(@"recognize")]
                            withBadge:@"shazam.logo.fill" fallback:@"waveform.badge.magnifyingglass" hex:@"007AFF"];
    recognizeRow.action = ^(UIViewController *vc) {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[IVLRecognizerViewController new]];
        nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        [vc presentViewController:nav animated:YES completion:nil];
    };

    // 4. Integrations & Stats — Discord, Scrobble, WebNowPlaying, Listening Stats
    IVLRow *discordPage = subpage(@"discord", @"Discord Rich Presence", @"bubble.left.and.bubble.right.fill", @"message.fill", @"5865F2", ^NSString *{
        return [IVLDiscord available] ? ([[IVLDiscord shared] enabled] ? IVLLoc(@"on") : IVLLoc(@"off")) : IVLLoc(@"discord_na_short");
    });

    IVLRow *scrobblePage = subpage(@"scrobble", IVLLoc(@"scrobble"), @"dot.radiowaves.left.and.right", @"antenna.radiowaves.left.and.right", @"FF3B30", ^NSString *{
        BOOL lf = [IVLScrobbler shared].lastfmLoggedIn && [IVLSettings boolForKey:IVLKeyLastfmEnabled];
        BOOL lb = [[IVLScrobbler shared].listenbrainzStatus length] > 0 && [IVLSettings boolForKey:IVLKeyListenBrainzEnabled] && ![[IVLScrobbler shared].listenbrainzStatus isEqualToString:IVLLoc(@"spotify_logged_out")];
        if (lf && lb) return @"Last.fm · LB";
        if (lf) return @"Last.fm";
        if ([IVLScrobbler shared].lastfmLoggedIn) return IVLLoc(@"off");
        return @"";
    });

    IVLRow *wnpPage = subpage(@"wnp", @"WebNowPlaying", @"desktopcomputer", @"display", @"30B0C7", ^NSString *{
        return IVLLoc([IVLSettings boolForKey:IVLKeyWNPEnabled] ? @"on" : @"off");
    });

    IVLRow *statsPage = [[IVLRow type:IVLRowLink key:@"" title:IVLLoc(@"stats")]
                         withBadge:@"chart.bar.fill" fallback:@"chart.bar.xaxis" hex:@"FF9500"];
    statsPage.detail = ^NSString *{ return IVLLoc([IVLSettings boolForKey:IVLKeyStatsEnabled] ? @"on" : @"off"); };
    statsPage.action = ^(UIViewController *vc) {
        [vc.navigationController pushViewController:[IVLStatsViewController new] animated:YES];
    };

    // 5. Data & About — Cache management, Developer (@axcyum), GitHub Repo, Version
    IVLRow *clear = [[IVLRow type:IVLRowAction key:@"" title:IVLLoc(@"clear_cache")]
                     withBadge:@"trash.fill" fallback:@"trash" hex:@"636366"];
    clear.detail = ^NSString *{
        return [NSByteCountFormatter stringFromByteCount:(long long)[[IVLLyricsService shared] cacheSize] countStyle:NSByteCountFormatterCountStyleFile];
    };
    clear.action = ^(UIViewController *vc) {
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:IVLLoc(@"clear_cache") message:IVLLoc(@"clear_cache_confirm") preferredStyle:UIAlertControllerStyleActionSheet];
        [sheet addAction:[UIAlertAction actionWithTitle:IVLLoc(@"clear_cache") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            [[IVLLyricsService shared] clearCache];
            [[IVLTranslator shared] clearCache];
            [((UITableViewController *)vc).tableView reloadData];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:IVLLoc(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
        sheet.popoverPresentationController.sourceView = vc.view;
        [vc presentViewController:sheet animated:YES completion:nil];
    };

    IVLRow *devLink = [[IVLRow type:IVLRowLink key:@"" title:IVLLoc(@"developer")]
                       withBadge:@"person.crop.circle.fill" fallback:@"person.fill" hex:@"3A3A3C"];
    devLink.external = YES;
    devLink.detail = ^NSString *{ return @"@axcyum"; };
    devLink.action = ^(UIViewController *vc) {
        NSURL *u = [NSURL URLWithString:kIVLAuthorURL];
        if (u) [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
    };

    IVLRow *repoLink = [[IVLRow type:IVLRowLink key:@"" title:IVLLoc(@"github_repo")]
                        withBadge:@"chevron.left.forwardslash.chevron.right" fallback:@"link" hex:@"24292F"];
    repoLink.external = YES;
    repoLink.detail = ^NSString *{ return @"axcyum/iOSYTM-Utils"; };
    repoLink.action = ^(UIViewController *vc) {
        NSURL *u = [NSURL URLWithString:kIVLRepoURL];
        if (u) [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
    };

    __weak typeof(self) weakSelf = self;
    IVLRow *checkUpdates = [[IVLRow type:IVLRowAction key:@"" title:IVLLoc(@"check_updates")]
                            withBadge:@"arrow.triangle.2.circlepath" fallback:@"arrow.clockwise" hex:@"30D158"];
    checkUpdates.busy = _checkingUpdate;
    checkUpdates.detail = ^NSString *{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return nil;
        return strongSelf->_checkingUpdate ? IVLLoc(@"checking_updates") : strongSelf->_updateStatus;
    };
    checkUpdates.action = ^(UIViewController *vc) {
        [weakSelf checkForUpdatesFrom:vc];
    };

    IVLRow *version = [[IVLRow type:IVLRowInfo key:@"" title:IVLLoc(@"version")]
                       withBadge:@"info.circle.fill" fallback:@"info.circle" hex:@"8E8E93"];
    version.detail = ^NSString *{ return IVLDisplayVersion(); };

    _sections = @[
        [IVLSection title:IVLLoc(@"sec_general") footer:nil rows:@[master, btnPage, appearancePage, displayPage]],
        [IVLSection title:IVLLoc(@"sec_lyrics_lang") footer:nil rows:@[sourcesPage, transPage, syncPage]],
        [IVLSection title:IVLLoc(@"sec_tools") footer:nil rows:@[lockPage, extDisplay, audioPage, sleepPage, recognizeRow]],
        [IVLSection title:IVLLoc(@"sec_integrations") footer:nil rows:@[discordPage, scrobblePage, wnpPage, statsPage]],
        [IVLSection title:IVLLoc(@"sec_data") footer:IVLLoc(@"footer_about") rows:@[clear, checkUpdates, devLink, repoLink, version]],
    ];
}

- (void)checkForUpdatesFrom:(UIViewController *)vc {
    if (_checkingUpdate) return;
    _checkingUpdate = YES;
    [self rebuild];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 12.0;
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    dispatch_group_t grp = dispatch_group_create();
    __block NSString *latestReleaseTag = nil;
    __block NSString *latestReleaseURL = nil;
    __block NSString *latestReleaseBody = nil;
    __block NSString *latestMainSHA = nil;
    __block NSString *latestMainMsg = nil;
    __block NSError *fetchErr = nil;
    __block BOOL gotAnyResponse = NO;

    NSMutableURLRequest *(^makeReq)(NSString *) = ^NSMutableURLRequest *(NSString *urlStr) {
        NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
        [r setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
        [r setValue:@"iOSYTM-Utils" forHTTPHeaderField:@"User-Agent"];
        return r;
    };

    dispatch_group_enter(grp);
    [[session dataTaskWithRequest:makeReq(kIVLReleasesAPI) completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSInteger code = [resp isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        if (code == 200 && data.length) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSArray class]]) {
                gotAnyResponse = YES;
                for (id item in (NSArray *)json) {
                    if (![item isKindOfClass:[NSDictionary class]]) continue;
                    NSDictionary *rel = item;
                    if ([rel[@"draft"] boolValue] || [rel[@"prerelease"] boolValue]) continue;
                    NSString *tag = [rel[@"tag_name"] isKindOfClass:[NSString class]] ? rel[@"tag_name"] : @"";
                    if (!tag.length || [tag isEqualToString:@"build-inputs"]) continue;
                    latestReleaseTag = tag;
                    latestReleaseURL = [rel[@"html_url"] isKindOfClass:[NSString class]] ? rel[@"html_url"] : nil;
                    latestReleaseBody = [rel[@"body"] isKindOfClass:[NSString class]] ? rel[@"body"] : nil;
                    break;
                }
            }
        } else if (err && !fetchErr) {
            fetchErr = err;
        }
        dispatch_group_leave(grp);
    }] resume];

    dispatch_group_enter(grp);
    [[session dataTaskWithRequest:makeReq(kIVLMainHeadAPI) completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSInteger code = [resp isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        if (code == 200 && data.length) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) {
                gotAnyResponse = YES;
                NSString *sha = [json[@"sha"] isKindOfClass:[NSString class]] ? json[@"sha"] : nil;
                if (sha.length >= 7) latestMainSHA = [sha substringToIndex:7];
                NSDictionary *commitObj = [json[@"commit"] isKindOfClass:[NSDictionary class]] ? json[@"commit"] : nil;
                NSString *msg = [commitObj[@"message"] isKindOfClass:[NSString class]] ? commitObj[@"message"] : nil;
                if (msg.length) {
                    latestMainMsg = [[msg componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet].firstObject
                                     stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                }
            }
        } else if (err && !fetchErr) {
            fetchErr = err;
        }
        dispatch_group_leave(grp);
    }] resume];

    __weak typeof(self) weakSelf = self;
    __weak UIViewController *weakVC = vc;
    dispatch_group_notify(grp, dispatch_get_main_queue(), ^{
        [session finishTasksAndInvalidate];
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_checkingUpdate = NO;

        if (!gotAnyResponse) {
            [strongSelf rebuild];
            UIViewController *presenter = weakVC ?: strongSelf;
            UIAlertController *a = [UIAlertController alertControllerWithTitle:IVLLoc(@"update_check_failed")
                                                                       message:fetchErr.localizedDescription
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:IVLLoc(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
            [a addAction:[UIAlertAction actionWithTitle:IVLLoc(@"open_github") style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
                NSURL *u = [NSURL URLWithString:kIVLRepoURL];
                if (u) [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
            }]];
            [presenter presentViewController:a animated:YES completion:nil];
            return;
        }

        BOOL hasNewRelease = latestReleaseTag.length > 0 && IVLCompareSemver(latestReleaseTag, @IVL_VERSION) == NSOrderedDescending;
        NSString *localCommit = @IVL_COMMIT;
        BOOL hasNewCommit = !latestReleaseTag.length && IVLHasRealCommit() && latestMainSHA.length >= 7
            && ![latestMainSHA.lowercaseString isEqualToString:[localCommit substringToIndex:MIN((NSUInteger)7, localCommit.length)].lowercaseString];

        if (hasNewRelease || hasNewCommit) {
            strongSelf->_updateStatus = IVLLoc(@"update_badge_new");
            [strongSelf rebuild];
            NSString *msg = nil;
            NSString *openURLStr = kIVLRepoURL;
            if (hasNewRelease) {
                NSString *notes = [latestReleaseBody stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (notes.length > 220) notes = [[notes substringToIndex:220] stringByAppendingString:@"…"];
                NSString *suffix = notes.length ? [NSString stringWithFormat:@"\n\n%@", notes] : @"";
                msg = [NSString stringWithFormat:IVLLoc(@"update_release_msg_fmt"), latestReleaseTag, @IVL_VERSION, suffix];
                if (latestReleaseURL.length) openURLStr = latestReleaseURL;
            } else {
                msg = [NSString stringWithFormat:IVLLoc(@"update_commit_msg_fmt"),
                       [localCommit substringToIndex:MIN((NSUInteger)7, localCommit.length)],
                       latestMainSHA,
                       latestMainMsg.length ? latestMainMsg : kIVLRepoURL];
                openURLStr = kIVLActionsURL;
            }
            UIViewController *presenter = weakVC ?: strongSelf;
            UIAlertController *a = [UIAlertController alertControllerWithTitle:IVLLoc(@"update_available")
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:IVLLoc(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
            [a addAction:[UIAlertAction actionWithTitle:IVLLoc(@"open_github") style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
                NSURL *u = [NSURL URLWithString:openURLStr];
                if (u) [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
            }]];
            [presenter presentViewController:a animated:YES completion:nil];
        } else {
            strongSelf->_updateStatus = IVLLoc(@"update_badge_latest");
            [strongSelf rebuild];
            UIViewController *presenter = weakVC ?: strongSelf;
            NSString *msg = [NSString stringWithFormat:IVLLoc(@"up_to_date_msg_fmt"), IVLDisplayVersion()];
            UIAlertController *a = [UIAlertController alertControllerWithTitle:IVLLoc(@"up_to_date")
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [presenter presentViewController:a animated:YES completion:nil];
        }
    });
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return _sections.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _sections[section].rows.count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return _sections[section].title; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { return _sections[section].footer; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    IVLRow *row = _sections[indexPath.section].rows[indexPath.row];

    if (row.type == IVLRowPreview) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        c.backgroundColor = [UIColor colorWithWhite:0.09 alpha:1.0];
        UILabel *lbl = [UILabel new];
        lbl.text = IVLLoc(@"preview_sample");
        lbl.numberOfLines = 2;
        lbl.font = [UIFont systemFontOfSize:[IVLSettings doubleForKey:IVLKeyFontSize] weight:UIFontWeightBold];
        lbl.textColor = [IVLTheme accentColor];
        lbl.textAlignment = ([IVLSettings integerForKey:IVLKeyAlignment] == 1) ? NSTextAlignmentCenter : NSTextAlignmentLeft;
        lbl.translatesAutoresizingMaskIntoConstraints = NO;
        [c.contentView addSubview:lbl];
        [NSLayoutConstraint activateConstraints:@[
            [lbl.leadingAnchor constraintEqualToAnchor:c.contentView.layoutMarginsGuide.leadingAnchor],
            [lbl.trailingAnchor constraintEqualToAnchor:c.contentView.layoutMarginsGuide.trailingAnchor],
            [lbl.topAnchor constraintEqualToAnchor:c.contentView.topAnchor constant:20],
            [lbl.bottomAnchor constraintEqualToAnchor:c.contentView.bottomAnchor constant:-20],
            [c.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:88],
        ]];
        _previewLabel = lbl;
        return c;
    }

    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    c.textLabel.text = row.title;
    c.textLabel.numberOfLines = 0;
    c.selectionStyle = UITableViewCellSelectionStyleNone;

    if (row.badgeHex.length) {
        c.imageView.image = IVLBadgeImage(row.symbol, row.fallbackSymbol, row.badgeHex);
    } else if (row.symbol.length) {
        c.imageView.image = [UIImage systemImageNamed:row.symbol];
    }

    switch (row.type) {
        case IVLRowSwitch: {
            UISwitch *s = [UISwitch new];
            s.on = row.disabled ? YES : (row.getBool ? row.getBool() : [IVLSettings boolForKey:row.key]);
            if (row.disabled) {
                s.enabled = NO;
                c.textLabel.textColor = UIColor.secondaryLabelColor;
                c.backgroundColor = [UIColor colorWithWhite:1 alpha:0.05];
                c.contentView.alpha = 0.55;
            } else {
                NSString *key = row.key;
                void (^custom)(BOOL) = row.setBool;
                [s addAction:[UIAction actionWithHandler:^(UIAction *a) {
                    BOOL on = ((UISwitch *)a.sender).on;
                    if (custom) custom(on); else [IVLSettings setBool:on forKey:key];
                }] forControlEvents:UIControlEventValueChanged];
            }
            c.accessoryView = s;
            break;
        }
        case IVLRowSegment: {
            NSArray *options = row.options ?: @[];
            NSArray<NSNumber *> *values = row.values;
            NSInteger cur = [IVLSettings integerForKey:row.key];
            NSInteger idx = values ? (NSInteger)[values indexOfObject:@(cur)] : cur;
            if (idx == NSNotFound || idx < 0 || idx >= (NSInteger)options.count) idx = 0;

            UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
            cfg.title = options.count ? options[idx] : @"";
            cfg.image = [UIImage systemImageNamed:@"chevron.up.chevron.down" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightSemibold]];
            cfg.imagePlacement = NSDirectionalRectEdgeTrailing;
            cfg.imagePadding = 5;
            cfg.contentInsets = NSDirectionalEdgeInsetsMake(4, 8, 4, 0);
            cfg.baseForegroundColor = UIColor.secondaryLabelColor;

            UIButton *btn = [UIButton buttonWithConfiguration:cfg primaryAction:nil];
            btn.showsMenuAsPrimaryAction = YES;
            NSString *key = row.key;
            __weak typeof(self) weakSelf = self;
            NSMutableArray<UIAction *> *actions = [NSMutableArray arrayWithCapacity:options.count];
            for (NSUInteger i = 0; i < options.count; i++) {
                UIAction *act = [UIAction actionWithTitle:options[i] image:nil identifier:nil handler:^(UIAction *a) {
                    [IVLSettings setObject:(values ? values[i] : @((NSInteger)i)) forKey:key];
                    [weakSelf rebuild];
                }];
                act.state = ((NSInteger)i == idx) ? UIMenuElementStateOn : UIMenuElementStateOff;
                [actions addObject:act];
            }
            btn.menu = [UIMenu menuWithTitle:@"" children:actions];
            [btn sizeToFit];
            c.accessoryView = btn;
            break;
        }
        case IVLRowStepper: {
            UIStepper *st = [UIStepper new];
            st.minimumValue = row.min; st.maximumValue = row.max; st.stepValue = row.step;
            st.value = [IVLSettings doubleForKey:row.key];
            NSString *key = row.key;
            NSString *(^fmt)(double) = row.format;
            [st addAction:[UIAction actionWithHandler:^(UIAction *a) {
                [IVLSettings setObject:@(((UIStepper *)a.sender).value) forKey:key];
            }] forControlEvents:UIControlEventValueChanged];
            UIView *wrap = [[UIView alloc] initWithFrame:CGRectMake(0, 0, st.intrinsicContentSize.width + 76, 32)];
            UILabel *val = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 68, 32)];
            val.textAlignment = NSTextAlignmentRight;
            val.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular];
            val.textColor = UIColor.secondaryLabelColor;
            val.text = row.format(st.value);
            st.frame = CGRectMake(76, 0, st.intrinsicContentSize.width, 32);
            [st addAction:[UIAction actionWithHandler:^(UIAction *a) { val.text = fmt(((UIStepper *)a.sender).value); }] forControlEvents:UIControlEventValueChanged];
            [wrap addSubview:val];
            [wrap addSubview:st];
            c.detailTextLabel.text = nil;
            c.accessoryView = wrap;
            break;
        }
        case IVLRowLink: {
            c.detailTextLabel.text = row.detail ? row.detail() : nil;
            c.selectionStyle = UITableViewCellSelectionStyleDefault;
            if (row.external) {
                UIImageView *ext = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.right" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold]]];
                ext.tintColor = UIColor.tertiaryLabelColor;
                c.accessoryView = ext;
            } else {
                c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            }
            break;
        }
        case IVLRowAction:
            if (row.badgeHex.length) {
                c.textLabel.textColor = UIColor.labelColor;
            } else {
                c.textLabel.textColor = row.destructive ? UIColor.systemRedColor : self.view.tintColor;
            }
            c.detailTextLabel.text = row.detail ? row.detail() : nil;
            if (row.busy) {
                UIActivityIndicatorView *sp = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
                [sp startAnimating];
                c.accessoryView = sp;
                c.selectionStyle = UITableViewCellSelectionStyleNone;
            } else {
                c.selectionStyle = UITableViewCellSelectionStyleDefault;
            }
            break;
        case IVLRowInfo:
            c.detailTextLabel.text = row.detail ? row.detail() : nil;
            c.detailTextLabel.numberOfLines = 0;
            break;
        case IVLRowText: {
            UITextField *f = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 170, 32)];
            f.textAlignment = NSTextAlignmentRight;
            f.placeholder = row.placeholder;
            f.keyboardType = row.keyboard;
            f.autocorrectionType = UITextAutocorrectionTypeNo;
            f.autocapitalizationType = UITextAutocapitalizationTypeNone;
            f.clearButtonMode = UITextFieldViewModeWhileEditing;
            f.secureTextEntry = row.secure;
            id v = row.key.length ? [IVLSettings objectForKey:row.key] : nil;
            f.text = [v isKindOfClass:[NSNumber class]] ? [v stringValue] : ([v length] ? v : nil);
            NSString *key = row.key;
            BOOL numeric = row.keyboard == UIKeyboardTypeNumberPad;
            void (^onText)(NSString *) = row.onText;
            [f addAction:[UIAction actionWithHandler:^(UIAction *a) {
                NSString *t = [((UITextField *)a.sender).text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] ?: @"";
                if (onText) { onText(t); return; }
                if ([t hasPrefix:@"#"]) t = [t substringFromIndex:1];
                [IVLSettings setObject:(numeric ? @(t.integerValue ?: 8974) : t) forKey:key];
            }] forControlEvents:UIControlEventEditingDidEnd];
            [f addAction:[UIAction actionWithHandler:^(UIAction *a) { [(UITextField *)a.sender resignFirstResponder]; }] forControlEvents:UIControlEventEditingDidEndOnExit];
            c.accessoryView = f;
            break;
        }
        case IVLRowSlider: {
            c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            double v = MAX(row.min, MIN(row.max, [IVLSettings doubleForKey:row.key]));
            UILabel *value = [UILabel new];
            value.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
            value.textAlignment = NSTextAlignmentRight;
            UISlider *sl = [UISlider new];
            sl.minimumValue = row.min; sl.maximumValue = row.max; sl.value = v;
            NSString *(^fmt)(double) = row.format;
            void (^onLive)(double) = row.onLive;
            double danger = row.danger, step = row.step > 0 ? row.step : 1;
            NSString *key = row.key;
            void (^paint)(double) = ^(double x) {
                BOOL hot = danger > 0 && x < danger;
                value.text = fmt ? fmt(x) : @(x).stringValue;
                value.textColor = hot ? UIColor.systemRedColor : UIColor.secondaryLabelColor;
                sl.minimumTrackTintColor = hot ? UIColor.systemRedColor : nil;
                if (onLive) onLive(x);
            };
            paint(v);
            [sl addAction:[UIAction actionWithHandler:^(UIAction *a) {
                UISlider *s2 = (UISlider *)a.sender;
                double x = round(s2.value / step) * step;
                paint(x);
            }] forControlEvents:UIControlEventValueChanged];
            [sl addAction:[UIAction actionWithHandler:^(UIAction *a) {
                UISlider *s2 = (UISlider *)a.sender;
                double x = round(s2.value / step) * step;
                s2.value = x;
                if (danger > 0 && x < danger) [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeWarning];
                [IVLSettings setObject:@(x) forKey:key];
            }] forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
            UILabel *title = [UILabel new];
            title.text = row.title;
            UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[title, value]];
            UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[top, sl]];
            stack.axis = UILayoutConstraintAxisVertical;
            stack.spacing = 8;
            stack.translatesAutoresizingMaskIntoConstraints = NO;
            [c.contentView addSubview:stack];
            [NSLayoutConstraint activateConstraints:@[
                [stack.leadingAnchor constraintEqualToAnchor:c.contentView.layoutMarginsGuide.leadingAnchor],
                [stack.trailingAnchor constraintEqualToAnchor:c.contentView.layoutMarginsGuide.trailingAnchor],
                [stack.topAnchor constraintEqualToAnchor:c.contentView.topAnchor constant:12],
                [stack.bottomAnchor constraintEqualToAnchor:c.contentView.bottomAnchor constant:-12],
            ]];
            return c;
        }
        case IVLRowColor: {
            NSString *hex = row.placeholder ?: @"";
            UIView *sw = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 26, 26)];
            sw.layer.cornerRadius = 13;
            sw.layer.borderWidth = 1;
            sw.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.3].CGColor;
            sw.backgroundColor = hex.length ? [IVLTheme colorFromHex:hex] : UIColor.clearColor;
            c.accessoryView = sw;
            NSString *cur = [IVLSettings objectForKey:row.key] ?: @"";
            if ([cur.uppercaseString isEqualToString:hex.uppercaseString]) c.textLabel.text = [@"✓ " stringByAppendingString:row.title];
            c.selectionStyle = UITableViewCellSelectionStyleDefault;
            break;
        }
        case IVLRowPreview:
            break;
    }
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    IVLRow *row = _sections[indexPath.section].rows[indexPath.row];
    if (row.type == IVLRowColor) { [IVLSettings setObject:row.placeholder ?: @"" forKey:row.key]; [self rebuild]; return; }
    if (row.action) row.action(self);
}

@end

#pragma mark - Providers (with unified Spotify & Subtitle Language section)

@implementation IVLProvidersViewController {
    NSMutableArray<NSString *> *_ids;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = IVLLoc(@"sec_sources");
    _ids = [[IVLSettings providerIDs] mutableCopy];
    self.tableView.editing = YES;
    self.tableView.allowsSelectionDuringEditing = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self.tableView selector:@selector(reloadData) name:IVLSpotifyStateDidChangeNotification object:nil];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self.tableView]; }

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

+ (NSString *)detailFor:(NSString *)pid {
    if ([pid isEqualToString:@"github"]) return IVLLoc(@"src_github");
    if ([pid isEqualToString:@"spicylyrics"]) return IVLLoc(@"src_spicylyrics");
    if ([pid isEqualToString:@"petitlyrics"]) return IVLLoc(@"src_petitlyrics");
    if ([pid isEqualToString:@"genius"]) return IVLLoc(@"src_genius");
    if ([pid isEqualToString:@"captions"]) return IVLLoc(@"src_captions");
    if ([pid isEqualToString:@"spotify"]) return IVLLoc(@"src_spotify");
    if ([pid isEqualToString:@"youtube"]) return IVLLoc(@"src_youtube");
    if ([pid isEqualToString:@"lyricsplus"]) return IVLLoc(@"src_lyricsplus");
    if ([pid isEqualToString:@"unison"]) return IVLLoc(@"src_unison");
    if ([pid isEqualToString:@"lyrically"]) return IVLLoc(@"src_lyrically");
    return IVLLoc(@"src_lrclib");
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? _ids.count : 3;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? IVLLoc(@"sources_order") : IVLLoc(@"sec_provider_options");
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == 0 ? IVLLoc(@"footer_sources_order") : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 1) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        c.editingAccessoryType = UITableViewCellAccessoryDisclosureIndicator;
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
        if (indexPath.row == 0) {
            c.imageView.image = IVLBadgeImage(@"music.note.list", @"music.note", @"1DB954");
            c.textLabel.text = @"Spotify";
            c.detailTextLabel.text = [IVLSpotify shared].loggedIn ? IVLLoc(@"spotify_logged_in") : IVLLoc(@"spotify_logged_out");
        } else if (indexPath.row == 1) {
            c.imageView.image = IVLBadgeImage(@"captions.bubble.fill", @"text.bubble.fill", @"0A84FF");
            c.textLabel.text = IVLLoc(@"caption_lang");
            NSString *code = [IVLSettings objectForKey:IVLKeyCaptionLang];
            c.detailTextLabel.text = code.length ? [IVLLanguagePickerViewController nameForCode:code] : IVLLoc(@"caption_auto");
        } else {
            c.imageView.image = IVLBadgeImage(@"chevron.left.forwardslash.chevron.right", @"folder.fill", @"24292F");
            c.textLabel.text = IVLLoc(@"github_lrc_repo");
            if (![IVLSettings boolForKey:IVLKeyProviderGitHub]) {
                c.detailTextLabel.text = IVLLoc(@"off");
            } else {
                NSUInteger cnt = [IVLSettings githubLRCRepos].count;
                c.detailTextLabel.text = cnt ? [NSString stringWithFormat:IVLLoc(@"github_lrc_repo_count_fmt"), (unsigned long)cnt] : IVLLoc(@"not_configured");
            }
        }
        return c;
    }

    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    NSString *pid = _ids[indexPath.row];
    BOOL isGitHubOff = [pid isEqualToString:@"github"] && ![IVLSettings boolForKey:IVLKeyProviderGitHub];
    c.textLabel.text = [NSString stringWithFormat:@"%ld. %@", (long)indexPath.row + 1, [IVLSettings nameForProvider:pid]];
    c.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    c.detailTextLabel.text = [IVLProvidersViewController detailFor:pid];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.detailTextLabel.numberOfLines = 0;
    if (isGitHubOff) {
        c.textLabel.textColor = UIColor.secondaryLabelColor;
        c.backgroundColor = [UIColor colorWithWhite:1 alpha:0.04];
        c.contentView.alpha = 0.5;
    }
    c.showsReorderControl = YES;
    UISwitch *sw = [UISwitch new];
    NSString *key = [IVLSettings enableKeyForProvider:pid];
    sw.on = [IVLSettings boolForKey:key];
    __weak UITableView *weakTable = tableView;
    [sw addAction:[UIAction actionWithHandler:^(UIAction *a) {
        [IVLSettings setBool:((UISwitch *)a.sender).on forKey:key];
        [weakTable reloadData];
    }] forControlEvents:UIControlEventValueChanged];
    c.editingAccessoryView = sw;
    return c;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath { return indexPath.section == 0; }
- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath { return UITableViewCellEditingStyleNone; }
- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath { return NO; }
- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath { return indexPath.section == 0; }

- (NSIndexPath *)tableView:(UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)sourceIndexPath toProposedIndexPath:(NSIndexPath *)proposedDestinationIndexPath {
    if (proposedDestinationIndexPath.section != 0) {
        return [NSIndexPath indexPathForRow:MAX(0, (NSInteger)_ids.count - 1) inSection:0];
    }
    return proposedDestinationIndexPath;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    if (from.section != 0 || to.section != 0) return;
    NSString *pid = _ids[from.row];
    [_ids removeObjectAtIndex:from.row];
    [_ids insertObject:pid atIndex:to.row];
    [IVLSettings setProviderIDs:_ids];
    dispatch_async(dispatch_get_main_queue(), ^{ [tableView reloadData]; });
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1) return;
    if (indexPath.row == 0) {
        [self.navigationController pushViewController:[[IVLSettingsViewController alloc] initWithPage:@"spotify"] animated:YES];
    } else if (indexPath.row == 1) {
        IVLLanguagePickerViewController *picker = [IVLLanguagePickerViewController new];
        picker.settingsKey = IVLKeyCaptionLang;
        [self.navigationController pushViewController:picker animated:YES];
    } else {
        [self.navigationController pushViewController:[IVLGitHubLRCReposViewController new] animated:YES];
    }
}

@end

#pragma mark - GitHub LRC Repositories Manager

@implementation IVLGitHubLRCReposViewController {
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *_repos;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = IVLLoc(@"github_lrc_repo");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(promptAddRepo)];
    _repos = [[IVLSettings githubLRCRepos] mutableCopy];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _repos = [[IVLSettings githubLRCRepos] mutableCopy];
    [self.tableView reloadData];
}

- (void)saveRepos {
    [IVLSettings setGitHubLRCRepos:_repos];
    [[IVLLyricsService shared] invalidateGitHubLRCCache];
    [self.tableView reloadData];
}

- (void)promptAddRepo {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:IVLLoc(@"github_lrc_add")
                                                               message:IVLLoc(@"github_lrc_add_msg")
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"owner/repo";
        tf.keyboardType = UIKeyboardTypeURL;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = IVLLoc(@"github_lrc_branch_placeholder");
        tf.keyboardType = UIKeyboardTypeASCIICapable;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [a addAction:[UIAlertAction actionWithTitle:IVLLoc(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [a addAction:[UIAlertAction actionWithTitle:IVLLoc(@"github_lrc_add_btn") style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSString *raw = a.textFields[0].text ?: @"";
        NSString *br = [a.textFields[1].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
        NSString *extracted = nil;
        NSString *norm = [IVLLyricsService parseGitHubOwnerRepo:raw extractedBranch:&extracted];
        if (!norm.length) {
            UIAlertController *err = [UIAlertController alertControllerWithTitle:IVLLoc(@"github_lrc_test_fail")
                                                                         message:IVLLoc(@"github_lrc_add_msg")
                                                                  preferredStyle:UIAlertControllerStyleAlert];
            [err addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [strongSelf presentViewController:err animated:YES completion:nil];
            return;
        }
        NSString *finalBranch = br.length ? br : (extracted ?: @"");
        BOOL exists = NO;
        for (NSDictionary<NSString *, NSString *> *d in strongSelf->_repos) {
            if ([d[@"repo"].lowercaseString isEqualToString:norm.lowercaseString] &&
                [(d[@"branch"] ?: @"").lowercaseString isEqualToString:finalBranch.lowercaseString]) {
                exists = YES;
                break;
            }
        }
        if (!exists) {
            [strongSelf->_repos addObject:@{ @"repo": norm, @"branch": finalBranch }];
            [strongSelf saveRepos];
        }
        [[IVLLyricsService shared] verifyGitHubLRCRepo:norm branch:finalBranch completion:^(BOOL ok, NSUInteger count, NSString *n, NSString *errMsg) {
            __strong typeof(weakSelf) s2 = weakSelf;
            if (!s2) return;
            NSString *title = ok ? IVLLoc(@"github_lrc_test_ok") : IVLLoc(@"github_lrc_test_fail");
            NSString *msg = ok ? [NSString stringWithFormat:IVLLoc(@"github_lrc_test_ok_fmt"), n ?: norm, (unsigned long)count] : (errMsg ?: @"Error");
            UIAlertController *res = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
            [res addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [s2 presentViewController:res animated:YES completion:nil];
        }];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    return _repos.count + 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 1 ? IVLLoc(@"github_lrc_repos_header") : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == 1 ? IVLLoc(@"footer_github_lrc") : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        c.textLabel.text = IVLLoc(@"github_lrc_use");
        UISwitch *sw = [UISwitch new];
        sw.on = [IVLSettings boolForKey:IVLKeyProviderGitHub];
        [sw addAction:[UIAction actionWithHandler:^(UIAction *a) {
            [IVLSettings setBool:((UISwitch *)a.sender).on forKey:IVLKeyProviderGitHub];
        }] forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
        return c;
    }

    if (indexPath.row == (NSInteger)_repos.count) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.textLabel.text = IVLLoc(@"github_lrc_add");
        c.textLabel.textColor = self.view.tintColor;
        c.imageView.image = [UIImage systemImageNamed:@"plus.circle.fill"];
        c.imageView.tintColor = self.view.tintColor;
        return c;
    }

    NSDictionary *d = _repos[indexPath.row];
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.textLabel.text = d[@"repo"];
    c.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    NSString *br = d[@"branch"];
    c.detailTextLabel.text = br.length ? [NSString stringWithFormat:@"branch: %@", br] : IVLLoc(@"github_lrc_branch_placeholder");
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.imageView.image = [UIImage systemImageNamed:@"folder.fill"];
    return c;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 1 && indexPath.row < (NSInteger)_repos.count;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete && indexPath.section == 1 && indexPath.row < (NSInteger)_repos.count) {
        [_repos removeObjectAtIndex:indexPath.row];
        [self saveRepos];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1) return;
    if (indexPath.row == (NSInteger)_repos.count) {
        [self promptAddRepo];
        return;
    }
    NSDictionary *d = _repos[indexPath.row];
    NSString *repo = d[@"repo"] ?: @"";
    NSString *branch = d[@"branch"] ?: @"";
    __weak typeof(self) weakSelf = self;
    [[IVLLyricsService shared] verifyGitHubLRCRepo:repo branch:branch completion:^(BOOL ok, NSUInteger count, NSString *norm, NSString *errMsg) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSString *title = ok ? IVLLoc(@"github_lrc_test_ok") : IVLLoc(@"github_lrc_test_fail");
        NSString *msg = ok ? [NSString stringWithFormat:IVLLoc(@"github_lrc_test_ok_fmt"), norm ?: repo, (unsigned long)count] : (errMsg ?: @"Error");
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [strongSelf presentViewController:a animated:YES completion:nil];
    }];
}

@end

#pragma mark - Language picker

@implementation IVLLanguagePickerViewController

+ (NSArray<NSArray<NSString *> *> *)languages {
    return @[
        @[@"ja", @"日本語"], @[@"en", @"English"], @[@"ko", @"한국어"], @[@"zh-CN", @"简体中文"], @[@"zh-TW", @"繁體中文"],
        @[@"es", @"Español"], @[@"fr", @"Français"], @[@"de", @"Deutsch"], @[@"it", @"Italiano"], @[@"pt", @"Português"],
        @[@"ru", @"Русский"], @[@"sv", @"Svenska"], @[@"cs", @"Čeština"], @[@"tr", @"Türkçe"], @[@"ar", @"العربية"],
        @[@"fa", @"فارسی"], @[@"hi", @"हिन्दी"], @[@"bn", @"বাংলা"], @[@"th", @"ไทย"], @[@"vi", @"Tiếng Việt"],
        @[@"id", @"Bahasa Indonesia"], @[@"ms", @"Bahasa Melayu"],
    ];
}

+ (NSString *)nameForCode:(NSString *)code {
    for (NSArray *l in [self languages]) if ([l[0] isEqualToString:code]) return l[1];
    return code ?: @"";
}

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _settingsKey = IVLKeyTranslationLang;
    return self;
}

- (BOOL)isCaption { return [_settingsKey isEqualToString:IVLKeyCaptionLang]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [self isCaption] ? IVLLoc(@"caption_lang") : IVLLoc(@"translation_lang");
    if (self.navigationController.viewControllers.firstObject == self) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    }
}

- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSArray<NSArray<NSString *> *> *)rows {
    NSArray *langs = [IVLLanguagePickerViewController languages];
    return [self isCaption] ? [@[@[@"", IVLLoc(@"caption_auto")]] arrayByAddingObjectsFromArray:langs] : langs;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return [self rows].count; }

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return [self isCaption] ? IVLLoc(@"footer_caption_lang") : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"l"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"l"];
    NSArray *l = [self rows][indexPath.row];
    c.textLabel.text = l[1];
    c.detailTextLabel.text = l[0];
    NSString *cur = [IVLSettings objectForKey:_settingsKey] ?: @"";
    c.accessoryType = [l[0] isEqualToString:cur] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray *l = [self rows][indexPath.row];
    [IVLSettings setObject:l[0] forKey:_settingsKey];
    [tableView reloadData];
    if (self.navigationController.viewControllers.firstObject == self) [self done];
    else [self.navigationController popViewControllerAnimated:YES];
}

@end
