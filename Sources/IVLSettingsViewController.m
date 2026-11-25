#import "IVLSettingsViewController.h"
#import "IVLSettings.h"
#import "IVLLocalization.h"
#import "IVLLyricsService.h"
#import "IVLTranslator.h"
#import "IVLSpotify.h"
#import "IVLDiscord.h"
#import "IVLWebNowPlaying.h"
#import "IVLExtras.h"
#import "IVLScrobbler.h"
#import "IVLRecognizer.h"

#ifndef IVL_VERSION
#define IVL_VERSION "1.0.0"
#endif

typedef NS_ENUM(NSInteger, IVLRowType) { IVLRowSwitch, IVLRowSegment, IVLRowStepper, IVLRowLink, IVLRowAction, IVLRowInfo, IVLRowText, IVLRowColor, IVLRowSlider };

@interface IVLRow : NSObject
@property (nonatomic) IVLRowType type;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSArray *options;           // segment titles
@property (nonatomic, copy) NSArray<NSNumber *> *values; // segment values (default 0..n-1)
@property (nonatomic) double min, max, step;
@property (nonatomic, copy) NSString *(^format)(double v);
@property (nonatomic, copy) void (^action)(UIViewController *vc);
@property (nonatomic, copy) NSString *(^detail)(void);
@property (nonatomic, copy) BOOL (^getBool)(void);           // custom switch (no settings key)
@property (nonatomic, copy) void (^setBool)(BOOL on);
@property (nonatomic, assign) BOOL destructive;
@property (nonatomic, copy) NSString *symbol;                 // SF Symbol for link rows
@property (nonatomic, copy) NSString *placeholder;            // text rows
@property (nonatomic) UIKeyboardType keyboard;
@property (nonatomic) double danger;                          // slider rows: values below are shown in red
@property (nonatomic) BOOL secure;                            // text rows stored in the keychain, never shown again
@property (nonatomic, copy) void (^onText)(NSString *text);   // text rows without a settings key
@end
@implementation IVLRow
+ (instancetype)type:(IVLRowType)t key:(NSString *)k title:(NSString *)title {
    IVLRow *r = [self new]; r.type = t; r.key = k; r.title = title; return r;
}
@end

@interface IVLSection : NSObject
@property (nonatomic, copy) NSString *title, *footer;
@property (nonatomic, copy) NSArray<IVLRow *> *rows;
@end
@implementation IVLSection
+ (instancetype)title:(NSString *)t footer:(NSString *)f rows:(NSArray *)rows {
    IVLSection *s = [self new]; s.title = t; s.footer = f; s.rows = rows; return s;
}
@end

@implementation IVLSettingsViewController {
    NSArray<IVLSection *> *_sections;
    NSString *_page;
}

- (instancetype)init { return [self initWithPage:nil]; }

- (instancetype)initWithPage:(NSString *)page {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _page = [page copy];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [_page isEqualToString:@"lock"] ? IVLLoc(@"sec_lock") : [_page isEqualToString:@"spotify"] ? @"Spotify"
               : [_page isEqualToString:@"discord"] ? @"Discord Rich Presence" : [_page isEqualToString:@"wnp"] ? @"WebNowPlaying"
               : [_page isEqualToString:@"extras"] ? IVLLoc(@"sec_extras") : [_page isEqualToString:@"accent"] ? IVLLoc(@"accent_color")
               : [_page isEqualToString:@"bgcolor"] ? IVLLoc(@"bg_color") : [_page isEqualToString:@"scrobble"] ? IVLLoc(@"scrobble") : @"ivLyrics";
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    if (!_page) self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
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

extern void IVLScrobblerSetSecret(NSString *account, NSString *value);

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

- (NSArray<IVLSection *> *)extrasSections {
    IVLRow *(^seg)(NSString *, NSString *, NSArray *) = ^(NSString *k, NSString *t, NSArray *o) {
        IVLRow *r = [IVLRow type:IVLRowSegment key:k title:t]; r.options = o; return r;
    };
    IVLRow *(^page)(NSString *, NSString *, NSString *(^)(void)) = ^(NSString *pageID, NSString *title, NSString *(^detail)(void)) {
        IVLRow *r = [IVLRow type:IVLRowLink key:@"" title:title];
        r.detail = detail;
        r.action = ^(UIViewController *vc) { [vc.navigationController pushViewController:[[IVLSettingsViewController alloc] initWithPage:pageID] animated:YES]; };
        return r;
    };
    IVLRow *theme = seg(IVLKeyBackground, IVLLoc(@"theme"), @[IVLLoc(@"bg_artwork"), IVLLoc(@"bg_solid"), IVLLoc(@"bg_dynamic"), IVLLoc(@"bg_black")]);
    IVLRow *accent = page(@"accent", IVLLoc(@"accent_color"), ^NSString *{ return [[IVLSettings objectForKey:IVLKeyAccentColor] length] ? [@"#" stringByAppendingString:[IVLSettings objectForKey:IVLKeyAccentColor]] : IVLLoc(@"color_default"); });
    IVLRow *bg = page(@"bgcolor", IVLLoc(@"bg_color"), ^NSString *{ return [[IVLSettings objectForKey:IVLKeyBackgroundColor] length] ? [@"#" stringByAppendingString:[IVLSettings objectForKey:IVLKeyBackgroundColor]] : IVLLoc(@"color_default"); });
    IVLRow *sleep = [IVLRow type:IVLRowLink key:@"" title:IVLLoc(@"sleep_timer")];
    sleep.symbol = @"moon.zzz";
    sleep.detail = ^NSString *{ return [[IVLSleepTimer shared] statusText]; };
    sleep.action = ^(UIViewController *vc) { [vc.navigationController pushViewController:[IVLSleepTimerViewController new] animated:YES]; };
    IVLRow *statsOn = [IVLRow type:IVLRowSwitch key:IVLKeyStatsEnabled title:IVLLoc(@"stats_record")];
    IVLRow *stats = [IVLRow type:IVLRowLink key:@"" title:IVLLoc(@"stats")];
    stats.symbol = @"chart.bar.xaxis";
    stats.action = ^(UIViewController *vc) { [vc.navigationController pushViewController:[IVLStatsViewController new] animated:YES]; };
    IVLRow *recognize = [IVLRow type:IVLRowLink key:@"" title:IVLLoc(@"recognize")];
    recognize.symbol = @"shazam.logo";
    recognize.action = ^(UIViewController *vc) {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[IVLRecognizerViewController new]];
        [vc presentViewController:nav animated:YES completion:nil];
    };
    IVLRow *scrobble = [IVLRow type:IVLRowLink key:@"" title:IVLLoc(@"scrobble")];
    scrobble.symbol = @"dot.radiowaves.left.and.right";
    scrobble.detail = ^NSString *{ return [IVLScrobbler shared].lastfmLoggedIn ? @"Last.fm" : @""; };
    scrobble.action = ^(UIViewController *vc) { [vc.navigationController pushViewController:[[IVLSettingsViewController alloc] initWithPage:@"scrobble"] animated:YES]; };
    IVLRow *openPlayer = [IVLRow type:IVLRowSwitch key:IVLKeyOpenPlayer title:IVLLoc(@"open_player")];
    return @[
        [IVLSection title:IVLLoc(@"player_style") footer:IVLLoc(@"footer_player_style") rows:@[openPlayer]],
        [IVLSection title:nil footer:IVLLoc(@"footer_recognize") rows:@[recognize]],
        [IVLSection title:nil footer:IVLLoc(@"footer_scrobble_link") rows:@[scrobble]],
        [IVLSection title:IVLLoc(@"theme") footer:IVLLoc(@"footer_theme") rows:@[theme, accent, bg]],
        [IVLSection title:nil footer:IVLLoc(@"footer_sleep") rows:@[sleep]],
        [IVLSection title:IVLLoc(@"stats") footer:IVLLoc(@"footer_stats") rows:@[statsOn, stats]],
    ];
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
        UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:files applicationActivities:nil];
        share.popoverPresentationController.sourceView = vc.view;
        [vc presentViewController:share animated:YES completion:nil];
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
    IVLRow *name = [IVLRow type:IVLRowText key:IVLKeyDiscordName title:IVLLoc(@"discord_name")];
    name.placeholder = @"YouTube Music iOS";
    IVLRow *songButton = [IVLRow type:IVLRowSwitch key:IVLKeyDiscordSongButton title:IVLLoc(@"discord_song_button")];
    IVLRow *githubButton = [IVLRow type:IVLRowSwitch key:IVLKeyDiscordGitHubButton title:IVLLoc(@"discord_github_button")];
    return @[
        [IVLSection title:nil footer:IVLLoc(@"footer_discord") rows:account],
        [IVLSection title:nil footer:nil rows:@[share, cover]],
        [IVLSection title:IVLLoc(@"discord_display") footer:IVLLoc(@"footer_discord_display") rows:@[name, songButton, githubButton]],
        [IVLSection title:IVLLoc(@"discord_interval") footer:IVLLoc(@"footer_discord_interval") rows:@[interval]],
        [IVLSection title:nil footer:nil rows:@[logs]],
    ];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self rebuild];
}

- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)buildSections {
    if ([_page isEqualToString:@"lock"]) { _sections = [self lockSections]; return; }
    if ([_page isEqualToString:@"spotify"]) { _sections = [self spotifySections]; return; }
    if ([_page isEqualToString:@"discord"]) { _sections = [self discordSections]; return; }
    if ([_page isEqualToString:@"wnp"]) { _sections = [self wnpSections]; return; }
    if ([_page isEqualToString:@"scrobble"]) { _sections = [self scrobbleSections]; return; }
    if ([_page isEqualToString:@"extras"]) { _sections = [self extrasSections]; return; }
    if ([_page isEqualToString:@"accent"]) { _sections = [self colorSectionsForKey:IVLKeyAccentColor includeDefault:IVLLoc(@"color_default")]; return; }
    if ([_page isEqualToString:@"bgcolor"]) { _sections = [self colorSectionsForKey:IVLKeyBackgroundColor includeDefault:IVLLoc(@"color_default")]; return; }
    IVLRow *(^page)(NSString *, NSString *, NSString *, NSString *(^)(void)) = ^(NSString *pageID, NSString *title, NSString *symbol, NSString *(^detail)(void)) {
        IVLRow *r = [IVLRow type:IVLRowLink key:@"" title:title];
        r.symbol = symbol;
        r.detail = detail;
        r.action = ^(UIViewController *vc) { [vc.navigationController pushViewController:[[IVLSettingsViewController alloc] initWithPage:pageID] animated:YES]; };
        return r;
    };
    IVLRow *lockPage = page(@"lock", IVLLoc(@"sec_lock"), @"lock.fill", ^NSString *{ return IVLLoc([IVLSettings boolForKey:IVLKeyLockEnabled] ? @"on" : @"off"); });
    IVLRow *spotifyPage = page(@"spotify", @"Spotify", @"music.note.list", ^NSString *{ return [IVLSpotify shared].loggedIn ? IVLLoc(@"spotify_logged_in") : IVLLoc(@"spotify_logged_out"); });
    IVLRow *discordPage = page(@"discord", @"Discord Rich Presence", @"bubble.left.and.bubble.right.fill", ^NSString *{
        return [IVLDiscord available] ? ([[IVLDiscord shared] enabled] ? IVLLoc(@"on") : IVLLoc(@"off")) : IVLLoc(@"discord_na_short");
    });

    IVLRow *wnpPage = page(@"wnp", @"WebNowPlaying", @"desktopcomputer", ^NSString *{ return IVLLoc([IVLSettings boolForKey:IVLKeyWNPEnabled] ? @"on" : @"off"); });
    IVLRow *extrasPage = page(@"extras", IVLLoc(@"sec_extras"), @"sparkles", ^NSString *{ return [IVLSleepTimer shared].active ? [[IVLSleepTimer shared] statusText] : @""; });
    IVLRow *(^sw)(NSString *, NSString *) = ^(NSString *k, NSString *t) { return [IVLRow type:IVLRowSwitch key:k title:t]; };
    IVLRow *(^seg)(NSString *, NSString *, NSArray *) = ^(NSString *k, NSString *t, NSArray *o) {
        IVLRow *r = [IVLRow type:IVLRowSegment key:k title:t]; r.options = o; return r;
    };

    IVLRow *size = [IVLRow type:IVLRowStepper key:IVLKeyFontSize title:IVLLoc(@"text_size")];
    size.min = 16; size.max = 52; size.step = 2;
    size.format = ^NSString *(double v) { return [NSString stringWithFormat:@"%.0f pt", v]; };

    IVLRow *lang = [IVLRow type:IVLRowLink key:IVLKeyTranslationLang title:IVLLoc(@"translation_lang")];
    lang.detail = ^NSString *{ return [IVLLanguagePickerViewController nameForCode:[IVLSettings objectForKey:IVLKeyTranslationLang]]; };
    lang.action = ^(UIViewController *vc) { [vc.navigationController pushViewController:[IVLLanguagePickerViewController new] animated:YES]; };

    IVLRow *sources = [IVLRow type:IVLRowLink key:IVLKeyProviderOrder title:IVLLoc(@"sources_order")];
    sources.detail = ^NSString *{
        NSMutableArray *names = [NSMutableArray array];
        for (NSString *pid in [IVLSettings enabledProviderIDs]) [names addObject:[IVLSettings nameForProvider:pid]];
        return names.count ? [names componentsJoinedByString:@" › "] : IVLLoc(@"off");
    };
    sources.action = ^(UIViewController *vc) { [vc.navigationController pushViewController:[IVLProvidersViewController new] animated:YES]; };

    IVLRow *captionLang = [IVLRow type:IVLRowLink key:IVLKeyCaptionLang title:IVLLoc(@"caption_lang")];
    captionLang.detail = ^NSString *{
        NSString *c = [IVLSettings objectForKey:IVLKeyCaptionLang];
        return [c length] ? [IVLLanguagePickerViewController nameForCode:c] : IVLLoc(@"caption_auto");
    };
    captionLang.action = ^(UIViewController *vc) {
        IVLLanguagePickerViewController *picker = [IVLLanguagePickerViewController new];
        picker.settingsKey = IVLKeyCaptionLang;
        [vc.navigationController pushViewController:picker animated:YES];
    };

    IVLRow *offset = [IVLRow type:IVLRowStepper key:IVLKeyGlobalOffset title:IVLLoc(@"global_offset")];
    offset.min = -3000; offset.max = 3000; offset.step = 50;
    offset.format = ^NSString *(double v) { return [NSString stringWithFormat:@"%+.2fs", v / 1000.0]; };

    IVLRow *resume = seg(IVLKeyAutoResume, IVLLoc(@"auto_resume"), @[IVLLoc(@"off"), @"3s", @"5s", @"10s"]);
    resume.values = @[@0, @3, @5, @10];

    IVLRow *clear = [IVLRow type:IVLRowAction key:@"" title:IVLLoc(@"clear_cache")];
    clear.detail = ^NSString *{
        return [NSByteCountFormatter stringFromByteCount:(long long)[[IVLLyricsService shared] cacheSize] countStyle:NSByteCountFormatterCountStyleFile];
    };
    clear.action = ^(UIViewController *vc) {
        [[IVLLyricsService shared] clearCache];
        [[IVLTranslator shared] clearCache];
        [((UITableViewController *)vc).tableView reloadData];
    };

    IVLRow *version = [IVLRow type:IVLRowInfo key:@"" title:IVLLoc(@"version")];
    version.detail = ^NSString *{ return @IVL_VERSION; };

    _sections = @[
        [IVLSection title:IVLLoc(@"sec_general") footer:IVLLoc(@"footer_general") rows:@[
            sw(IVLKeyEnabled, IVLLoc(@"enabled")),
            sw(IVLKeyShowButton, IVLLoc(@"show_button")),
            sw(IVLKeyMiniLyric, IVLLoc(@"mini_lyric")),
            sw(IVLKeyKeepAwake, IVLLoc(@"keep_awake")),
        ]],
        [IVLSection title:IVLLoc(@"sec_integrations") footer:nil rows:@[lockPage, spotifyPage, discordPage, wnpPage]],
        [IVLSection title:IVLLoc(@"sec_extras") footer:IVLLoc(@"footer_extras") rows:@[extrasPage]],
        [IVLSection title:IVLLoc(@"sec_display") footer:IVLLoc(@"footer_display") rows:@[
            size,
            seg(IVLKeyAlignment, IVLLoc(@"alignment"), @[IVLLoc(@"align_left"), IVLLoc(@"align_center")]),
            sw(IVLKeyKaraoke, IVLLoc(@"karaoke")),
            sw(IVLKeyShowBreaks, IVLLoc(@"show_breaks")),
        ]],
        [IVLSection title:IVLLoc(@"sec_translation") footer:IVLLoc(@"footer_translation") rows:@[
            sw(IVLKeyTranslation, IVLLoc(@"translation")),
            lang,
            seg(IVLKeyPronunciation, IVLLoc(@"pronunciation"), @[IVLLoc(@"off"), IVLLoc(@"romaji"), IVLLoc(@"kana")]),
        ]],
        [IVLSection title:IVLLoc(@"sec_sources") footer:IVLLoc(@"footer_sources") rows:@[sources, captionLang]],
        [IVLSection title:IVLLoc(@"sec_sync") footer:IVLLoc(@"footer_sync") rows:@[offset, resume]],
        [IVLSection title:IVLLoc(@"sec_data") footer:nil rows:@[clear]],
        [IVLSection title:IVLLoc(@"sec_about") footer:IVLLoc(@"footer_about") rows:@[version]],
    ];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return _sections.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _sections[section].rows.count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return _sections[section].title; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { return _sections[section].footer; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    IVLRow *row = _sections[indexPath.section].rows[indexPath.row];
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    c.textLabel.text = row.title;
    c.textLabel.numberOfLines = 0;
    c.selectionStyle = UITableViewCellSelectionStyleNone;

    switch (row.type) {
        case IVLRowSwitch: {
            UISwitch *s = [UISwitch new];
            s.on = row.getBool ? row.getBool() : [IVLSettings boolForKey:row.key];
            NSString *key = row.key;
            void (^custom)(BOOL) = row.setBool;
            [s addAction:[UIAction actionWithHandler:^(UIAction *a) {
                BOOL on = ((UISwitch *)a.sender).on;
                if (custom) custom(on); else [IVLSettings setBool:on forKey:key];
            }] forControlEvents:UIControlEventValueChanged];
            c.accessoryView = s;
            break;
        }
        case IVLRowSegment: {
            UISegmentedControl *sc = [[UISegmentedControl alloc] initWithItems:row.options];
            NSArray<NSNumber *> *values = row.values;
            NSInteger cur = [IVLSettings integerForKey:row.key];
            NSInteger idx = values ? (NSInteger)[values indexOfObject:@(cur)] : cur;
            sc.selectedSegmentIndex = (idx == NSNotFound || idx >= (NSInteger)row.options.count) ? 0 : idx;
            NSString *key = row.key;
            [sc addAction:[UIAction actionWithHandler:^(UIAction *a) {
                NSInteger i = ((UISegmentedControl *)a.sender).selectedSegmentIndex;
                [IVLSettings setObject:(values ? values[i] : @(i)) forKey:key];
            }] forControlEvents:UIControlEventValueChanged];
            [sc sizeToFit];
            c.accessoryView = sc;
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
        case IVLRowLink:
            if (row.symbol) c.imageView.image = [UIImage systemImageNamed:row.symbol];
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            c.detailTextLabel.text = row.detail ? row.detail() : nil;
            c.selectionStyle = UITableViewCellSelectionStyleDefault;
            break;
        case IVLRowAction:
            c.textLabel.textColor = (row.destructive || [row.title isEqualToString:IVLLoc(@"clear_cache")]) ? UIColor.systemRedColor : UIColor.systemBlueColor;
            c.detailTextLabel.text = row.detail ? row.detail() : nil;
            c.selectionStyle = UITableViewCellSelectionStyleDefault;
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
            // full-width slider under the title; values below `danger` are the "danger zone"
            c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            double v = MAX(row.min, MIN(row.max, [IVLSettings doubleForKey:row.key]));
            UILabel *value = [UILabel new];
            value.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
            value.textAlignment = NSTextAlignmentRight;
            UISlider *sl = [UISlider new];
            sl.minimumValue = row.min; sl.maximumValue = row.max; sl.value = v;
            NSString *(^fmt)(double) = row.format;
            double danger = row.danger, step = row.step > 0 ? row.step : 1;
            NSString *key = row.key;
            void (^paint)(double) = ^(double x) {
                BOOL hot = danger > 0 && x < danger;
                value.text = fmt ? fmt(x) : @(x).stringValue;
                value.textColor = hot ? UIColor.systemRedColor : UIColor.secondaryLabelColor;
                sl.minimumTrackTintColor = hot ? UIColor.systemRedColor : nil;
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

#pragma mark - Providers

@implementation IVLProvidersViewController {
    NSMutableArray<NSString *> *_ids;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = IVLLoc(@"sec_sources");
    _ids = [[IVLSettings providerIDs] mutableCopy];
    self.tableView.editing = YES;
    self.tableView.allowsSelectionDuringEditing = NO;
}

+ (NSString *)detailFor:(NSString *)pid {
    if ([pid isEqualToString:@"captions"]) return IVLLoc(@"src_captions");
    if ([pid isEqualToString:@"spotify"]) return IVLLoc(@"src_spotify");
    if ([pid isEqualToString:@"youtube"]) return IVLLoc(@"src_youtube");
    if ([pid isEqualToString:@"lyricsplus"]) return IVLLoc(@"src_lyricsplus");
    if ([pid isEqualToString:@"unison"]) return IVLLoc(@"src_unison");
    if ([pid isEqualToString:@"lyrically"]) return IVLLoc(@"src_lyrically");
    return IVLLoc(@"src_lrclib");
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _ids.count; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { return IVLLoc(@"footer_sources_order"); }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSString *pid = _ids[indexPath.row];
    c.textLabel.text = [NSString stringWithFormat:@"%ld. %@", (long)indexPath.row + 1, [IVLSettings nameForProvider:pid]];
    c.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    c.detailTextLabel.text = [IVLProvidersViewController detailFor:pid];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.detailTextLabel.numberOfLines = 0;
    c.showsReorderControl = YES;
    UISwitch *sw = [UISwitch new];
    NSString *key = [IVLSettings enableKeyForProvider:pid];
    sw.on = [IVLSettings boolForKey:key];
    [sw addAction:[UIAction actionWithHandler:^(UIAction *a) { [IVLSettings setBool:((UISwitch *)a.sender).on forKey:key]; }] forControlEvents:UIControlEventValueChanged];
    c.editingAccessoryView = sw;
    return c;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath { return UITableViewCellEditingStyleNone; }
- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath { return NO; }
- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath { return YES; }

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    NSString *pid = _ids[from.row];
    [_ids removeObjectAtIndex:from.row];
    [_ids insertObject:pid atIndex:to.row];
    [IVLSettings setProviderIDs:_ids];
    dispatch_async(dispatch_get_main_queue(), ^{ [tableView reloadData]; });   // renumber
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
