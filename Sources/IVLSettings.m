#import "IVLSettings.h"

NSNotificationName const IVLSettingsDidChangeNotification = @"IVLSettingsDidChangeNotification";

NSString *const IVLKeyEnabled = @"enabled";
NSString *const IVLKeyShowButton = @"showButton";
NSString *const IVLKeyMiniLyric = @"miniLyric";
NSString *const IVLKeyKeepAwake = @"keepAwake";
NSString *const IVLKeyFontSize = @"fontSize";
NSString *const IVLKeyAlignment = @"alignment";
NSString *const IVLKeyKaraoke = @"karaoke";
NSString *const IVLKeyShowBreaks = @"showBreaks";
NSString *const IVLKeyBackground = @"background";
NSString *const IVLKeyTranslation = @"translation";
NSString *const IVLKeyTranslationLang = @"translationLang";
NSString *const IVLKeyPronunciation = @"pronunciation";
NSString *const IVLKeyProviderUnison = @"providerUnison";
NSString *const IVLKeyProviderLRCLIB = @"providerLRCLIB";
NSString *const IVLKeyProviderYouTube = @"providerYouTube";
NSString *const IVLKeyProviderLyricsPlus = @"providerLyricsPlus";
NSString *const IVLKeyProviderLyrically = @"providerLyrically";
NSString *const IVLKeyProviderGitHub = @"providerGitHub";
NSString *const IVLKeyGitHubLRCRepo = @"githubLRCRepo";
NSString *const IVLKeyGitHubLRCBranch = @"githubLRCBranch";
NSString *const IVLKeyGitHubLRCRepos = @"githubLRCRepos";
NSString *const IVLKeyProviderOrder = @"providerOrderList";
NSString *const IVLKeyGlobalOffset = @"globalOffset";
NSString *const IVLKeyAutoResume = @"autoResume";
NSString *const IVLKeyButtonX = @"buttonX";
NSString *const IVLKeyButtonY = @"buttonY";
NSString *const IVLKeySongOffsets = @"songOffsets";
NSString *const IVLKeySongProviders = @"songProviders";
NSString *const IVLKeyLockEnabled = @"lockEnabled";
NSString *const IVLKeyLockAnimation = @"lockAnimation";
NSString *const IVLKeyLockKaraoke = @"lockKaraoke";
NSString *const IVLKeyLockTranslation = @"lockTranslation";
NSString *const IVLKeyLockLead = @"lockLead";
NSString *const IVLKeyProviderSpotify = @"providerSpotify";
NSString *const IVLKeyProviderCaptions = @"providerCaptions";
NSString *const IVLKeyCaptionLang = @"captionLang";
NSString *const IVLKeyDiscordInterval = @"discordInterval";
NSString *const IVLKeyDiscordStatusDisplay = @"discordStatusDisplay";
NSString *const IVLKeyDiscordName = @"discordName";
NSString *const IVLKeyDiscordSongButton = @"discordSongButton";
NSString *const IVLKeyDiscordGitHubButton = @"discordGitHubButton";
NSString *const IVLKeyDiscordGitHubURL = @"discordGitHubURL";
NSString *const IVLKeyLastfmEnabled = @"lastfmEnabled";
NSString *const IVLKeyLastfmKey = @"lastfmKey";
NSString *const IVLKeyLastfmUser = @"lastfmUser";
NSString *const IVLKeyListenBrainzEnabled = @"listenbrainzEnabled";
NSString *const IVLKeyOpenPlayer = @"openPlayer";
NSString *const IVLKeyImmersivePlayer = @"immersivePlayer";
NSString *const IVLKeyAMLyrics = @"amLyrics";
NSString *const IVLKeyWNPEnabled = @"wnpEnabled";
NSString *const IVLKeyWNPHost = @"wnpHost";
NSString *const IVLKeyWNPPort = @"wnpPort";
NSString *const IVLKeyWNPControl = @"wnpControl";
NSString *const IVLKeyStatsEnabled = @"statsEnabled";
NSString *const IVLKeyAccentColor = @"accentColor";
NSString *const IVLKeyBackgroundColor = @"backgroundColor";

static NSString *const kDomain = @"ivLyricsYTM";

static NSString *IVLLocCaptionsName(void) {
    NSString *l = [NSLocale preferredLanguages].firstObject ?: @"en";
    if ([l hasPrefix:@"ja"]) return @"動画の字幕";
    if ([l hasPrefix:@"ko"]) return @"동영상 자막";
    return @"Video captions";
}

@implementation IVLSettings

+ (NSDictionary *)defaults {
    static NSDictionary *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = @{
            IVLKeyEnabled: @YES,
            IVLKeyShowButton: @YES,
            IVLKeyMiniLyric: @YES,
            IVLKeyKeepAwake: @YES,
            IVLKeyFontSize: @28.0,
            IVLKeyAlignment: @0,
            IVLKeyKaraoke: @YES,
            IVLKeyShowBreaks: @YES,
            IVLKeyBackground: @0,
            IVLKeyTranslation: @NO,
            IVLKeyTranslationLang: [self defaultTranslationLanguage],
            IVLKeyPronunciation: @0,
            IVLKeyProviderUnison: @YES,
            IVLKeyProviderLRCLIB: @YES,
            IVLKeyProviderYouTube: @YES,
            IVLKeyProviderLyricsPlus: @YES,
            IVLKeyProviderLyrically: @YES,
            IVLKeyProviderGitHub: @NO,
            IVLKeyGitHubLRCRepo: @"",
            IVLKeyGitHubLRCBranch: @"",
            IVLKeyGitHubLRCRepos: @[],
            IVLKeyProviderOrder: [self knownProviders],
            IVLKeyGlobalOffset: @0,
            IVLKeyAutoResume: @3,
            IVLKeyButtonX: @0.9,
            IVLKeyButtonY: @0.2,
            IVLKeySongOffsets: @{},
            IVLKeySongProviders: @{},
            IVLKeyLockEnabled: @YES,
            IVLKeyLockAnimation: @YES,
            IVLKeyLockKaraoke: @YES,
            IVLKeyLockTranslation: @YES,
            IVLKeyLockLead: @250,
            IVLKeyProviderSpotify: @YES,
            IVLKeyProviderCaptions: @YES,
            IVLKeyCaptionLang: @"",
            IVLKeyDiscordInterval: @15,
            IVLKeyDiscordStatusDisplay: @0,
            IVLKeyDiscordName: @"YouTube Music iOS",
            IVLKeyDiscordSongButton: @YES,
            IVLKeyDiscordGitHubButton: @YES,
            IVLKeyDiscordGitHubURL: @"https://github.com/axcyum/iOSYTM-Utils",
            IVLKeyLastfmEnabled: @YES,
            IVLKeyLastfmKey: @"",
            IVLKeyListenBrainzEnabled: @YES,
            IVLKeyOpenPlayer: @NO,
            IVLKeyImmersivePlayer: @NO,
            IVLKeyAMLyrics: @NO,
            IVLKeyWNPEnabled: @NO,
            IVLKeyWNPHost: @"",
            IVLKeyWNPPort: @8974,
            IVLKeyWNPControl: @YES,
            IVLKeyStatsEnabled: @YES,
            IVLKeyAccentColor: @"",
            IVLKeyBackgroundColor: @"",
        };
    });
    return d;
}

+ (NSString *)defaultTranslationLanguage {
    NSString *pref = [NSLocale preferredLanguages].firstObject ?: @"en";
    if ([pref hasPrefix:@"zh-Hant"] || [pref hasPrefix:@"zh-TW"] || [pref hasPrefix:@"zh-HK"]) return @"zh-TW";
    if ([pref hasPrefix:@"zh"]) return @"zh-CN";
    NSString *code = [[pref componentsSeparatedByString:@"-"] firstObject];
    return code.length ? code : @"en";
}

+ (NSArray<NSString *> *)knownProviders {
    // synced built-in sources first, optional GitHub LRC repo at the bottom (OFF by default)
    return @[@"youtube", @"lyricsplus", @"spotify", @"captions", @"unison", @"lyrically", @"lrclib", @"github"];
}

+ (NSArray<NSString *> *)providerIDs {
    NSArray *known = [self knownProviders];
    NSMutableArray *out = [NSMutableArray array];
    id saved = [self store][IVLKeyProviderOrder];
    if ([saved isKindOfClass:[NSArray class]]) {
        for (id pid in saved) if ([known containsObject:pid] && ![out containsObject:pid]) [out addObject:pid];
    }
    // providers added in an update go to their default position, not to the end
    for (NSUInteger i = 0; i < known.count; i++) {
        if (![out containsObject:known[i]]) [out insertObject:known[i] atIndex:MIN(i, out.count)];
    }
    return out;
}

+ (void)setProviderIDs:(NSArray<NSString *> *)ids { [self setObject:[ids copy] forKey:IVLKeyProviderOrder]; }

+ (NSString *)enableKeyForProvider:(NSString *)pid {
    return @{ @"github": IVLKeyProviderGitHub, @"captions": IVLKeyProviderCaptions, @"spotify": IVLKeyProviderSpotify, @"youtube": IVLKeyProviderYouTube, @"lyricsplus": IVLKeyProviderLyricsPlus, @"unison": IVLKeyProviderUnison,
              @"lyrically": IVLKeyProviderLyrically, @"lrclib": IVLKeyProviderLRCLIB }[pid] ?: @"";
}

+ (NSString *)nameForProvider:(NSString *)pid {
    return @{ @"github": @"GitHub LRC", @"captions": IVLLocCaptionsName(), @"spotify": @"Spotify", @"youtube": @"YouTube Music", @"lyricsplus": @"LyricsPlus", @"unison": @"Unison", @"lyrically": @"Lyrically", @"lrclib": @"LRCLIB" }[pid] ?: pid;
}

+ (NSArray<NSString *> *)enabledProviderIDs {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *pid in [self providerIDs]) if ([self boolForKey:[self enableKeyForProvider:pid]]) [out addObject:pid];
    return out;
}

+ (NSDictionary *)store {
    return [[NSUserDefaults standardUserDefaults] dictionaryForKey:kDomain] ?: @{};
}

+ (id)objectForKey:(NSString *)key {
    id v = [self store][key];
    return v ?: [self defaults][key];
}

+ (BOOL)boolForKey:(NSString *)key { return [[self objectForKey:key] boolValue]; }
+ (NSInteger)integerForKey:(NSString *)key { return [[self objectForKey:key] integerValue]; }
+ (double)doubleForKey:(NSString *)key { return [[self objectForKey:key] doubleValue]; }

+ (void)setObject:(id)value forKey:(NSString *)key {
    NSMutableDictionary *m = [[self store] mutableCopy];
    if (value) m[key] = value; else [m removeObjectForKey:key];
    [[NSUserDefaults standardUserDefaults] setObject:m forKey:kDomain];
    [[NSNotificationCenter defaultCenter] postNotificationName:IVLSettingsDidChangeNotification object:key];
}

+ (void)setBool:(BOOL)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }

+ (NSInteger)songOffsetForVideoID:(NSString *)videoID {
    if (!videoID.length) return 0;
    NSDictionary *d = [self objectForKey:IVLKeySongOffsets];
    return [d isKindOfClass:[NSDictionary class]] ? [d[videoID] integerValue] : 0;
}

+ (void)setSongOffset:(NSInteger)ms forVideoID:(NSString *)videoID {
    if (!videoID.length) return;
    NSDictionary *d = [self objectForKey:IVLKeySongOffsets];
    NSMutableDictionary *m = [d isKindOfClass:[NSDictionary class]] ? [d mutableCopy] : [NSMutableDictionary dictionary];
    if (ms == 0) [m removeObjectForKey:videoID]; else m[videoID] = @(ms);
    [self setObject:m forKey:IVLKeySongOffsets];
}

+ (NSString *)pinnedProviderForKeys:(NSArray<NSString *> *)keys {
    NSDictionary *d = [self objectForKey:IVLKeySongProviders];
    if (![d isKindOfClass:[NSDictionary class]]) return nil;
    for (NSString *k in keys) {
        NSString *v = d[k];
        if ([v isKindOfClass:[NSString class]] && v.length) return v;
    }
    return nil;
}

+ (void)setPinnedProvider:(NSString *)providerID forKeys:(NSArray<NSString *> *)keys {
    if (!keys.count) return;
    NSDictionary *d = [self objectForKey:IVLKeySongProviders];
    NSMutableDictionary *m = [d isKindOfClass:[NSDictionary class]] ? [d mutableCopy] : [NSMutableDictionary dictionary];
    for (NSString *k in keys) {
        if (!k.length) continue;
        if (providerID.length) m[k] = providerID;
        else [m removeObjectForKey:k];
    }
    [self setObject:m forKey:IVLKeySongProviders];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)githubLRCRepos {
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *out = [NSMutableArray array];
    id arr = [self objectForKey:IVLKeyGitHubLRCRepos];
    if ([arr isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)arr) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSString *r = [item[@"repo"] isKindOfClass:[NSString class]] ? item[@"repo"] : @"";
            NSString *b = [item[@"branch"] isKindOfClass:[NSString class]] ? item[@"branch"] : @"";
            if (r.length) [out addObject:@{ @"repo": r, @"branch": b ?: @"" }];
        }
    }
    if (!out.count) {
        NSString *legacy = [self objectForKey:IVLKeyGitHubLRCRepo];
        if ([legacy isKindOfClass:[NSString class]] && legacy.length) {
            NSString *lb = [self objectForKey:IVLKeyGitHubLRCBranch];
            [out addObject:@{ @"repo": legacy, @"branch": ([lb isKindOfClass:[NSString class]] ? lb : @"") ?: @"" }];
        }
    }
    return out;
}

+ (void)setGitHubLRCRepos:(NSArray<NSDictionary<NSString *, NSString *> *> *)repos {
    NSMutableArray *clean = [NSMutableArray array];
    for (NSDictionary *d in repos) {
        NSString *r = [d[@"repo"] isKindOfClass:[NSString class]] ? d[@"repo"] : @"";
        NSString *b = [d[@"branch"] isKindOfClass:[NSString class]] ? d[@"branch"] : @"";
        if (r.length) [clean addObject:@{ @"repo": r, @"branch": b ?: @"" }];
    }
    [self setObject:clean forKey:IVLKeyGitHubLRCRepos];
    [self setObject:@"" forKey:IVLKeyGitHubLRCRepo];
    [self setObject:@"" forKey:IVLKeyGitHubLRCBranch];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end
