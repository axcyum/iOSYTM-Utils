// Discord Rich Presence — ported from axcyum/YTMusic-iOS-Presence (GPL-3.0) src/Presence.mm.
// Changes: settings live in the ivLyrics settings screen (no UIAlertController sheet),
// cover art comes from the shared ivLyrics track model, hooks are shared with ivLyrics.

#import "IVLDiscord.h"
#import "IVLDiscordLog.h"
#import "IVLPlaybackManager.h"
#import "IVLLockScreen.h"
#import "IVLLyricsService+Private.h"
#import "IVLSettings.h"
#import <MediaPlayer/MediaPlayer.h>
#import <Security/Security.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <cmath>
#include <cstring>
#include <memory>
#include <string>

NSNotificationName const IVLDiscordStatusDidChangeNotification = @"IVLDiscordStatusDidChangeNotification";

#ifndef IVL_VERSION
#define IVL_VERSION "1.0.0"
#endif

#ifndef IVL_DISCORD_APP_ID
#define IVL_DISCORD_APP_ID 1559887091171852310ULL
#define IVL_DISCORD_APP_ID_STRING "1559887091171852310"
#endif

static NSString *const kEnabledKey = @"ivLyrics.discord.enabled";
static NSString *const kCoverKey = @"ivLyrics.discord.cover";
static NSString *const kTokenService = @"ivLyrics.discord.oauth";

#if IVL_DISCORD
extern "C" int IVLDiscordBindStubs(void *handle);   // generated: tools/gen_discord_stubs.py
#endif

static NSString *gDiscordLoadInfo = @"";

/// The SDK is never linked. It is dlopen()ed from wherever it can be found and every
/// Discord_* stub is bound to it, so it works without framework injection (LiveContainer):
/// putting `discord_partner_sdk.dylib` next to ivLyricsYTM.dylib is enough.
static BOOL IVLDiscordLoad(void) {
#if IVL_DISCORD
    static BOOL loaded;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        // 1. already loaded (injected as a tweak / framework)
        for (uint32_t i = 0; i < _dyld_image_count(); i++) {
            const char *name = _dyld_get_image_name(i);
            if (name && strstr(name, "discord_partner_sdk")) [candidates addObject:@(name)];
        }
        // 2. next to this dylib
        Dl_info info;
        if (dladdr((const void *)&IVLDiscordLoad, &info) && info.dli_fname) {
            NSString *dir = [@(info.dli_fname) stringByDeletingLastPathComponent];
            for (NSString *n in @[@"discord_partner_sdk.dylib", @"libdiscord_partner_sdk.dylib",
                                  @"discord_partner_sdk.framework/discord_partner_sdk", @"discord_partner_sdk"]) {
                [candidates addObject:[dir stringByAppendingPathComponent:n]];
            }
        }
        // 3. the app's Frameworks folder
        NSString *fw = NSBundle.mainBundle.privateFrameworksPath;
        if (fw) {
            [candidates addObject:[fw stringByAppendingPathComponent:@"discord_partner_sdk.framework/discord_partner_sdk"]];
            [candidates addObject:[fw stringByAppendingPathComponent:@"discord_partner_sdk.dylib"]];
        }
        NSMutableArray *notes = [NSMutableArray array];
        for (NSString *path in candidates) {
            BOOL already = [path hasPrefix:@"/"] && ![NSFileManager.defaultManager fileExistsAtPath:path] ? NO : YES;
            if (!already) continue;
            void *h = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
            if (!h) { const char *e = dlerror(); [notes addObject:[NSString stringWithFormat:@"%@: %s", path.lastPathComponent, e ?: "dlopen failed"]]; continue; }
            int missing = IVLDiscordBindStubs(h);
            if (missing == 0) { loaded = YES; gDiscordLoadInfo = path; return; }
            [notes addObject:[NSString stringWithFormat:@"%@: %d symbols missing (SDK version mismatch)", path.lastPathComponent, missing]];
        }
        gDiscordLoadInfo = notes.count ? [notes componentsJoinedByString:@"\n"] : @"";
    });
    return loaded;
#else
    return NO;
#endif
}

#if IVL_DISCORD

#define DISCORDPP_IMPLEMENTATION
#include <discord_partner_sdk/discordpp.h>

static NSString *const kAccount = @IVL_DISCORD_APP_ID_STRING;
static std::string UTF8(NSString *s) { return s ? std::string(s.UTF8String ?: "") : ""; }
static NSString *Text(id v) { return [v isKindOfClass:NSString.class] ? v : @""; }
static double Number(id v, double fallback) {
    if (![v isKindOfClass:NSNumber.class]) return fallback;
    double n = [v doubleValue]; return std::isfinite(n) ? n : fallback;
}
/// Discord limits: 128 bytes, at least 2 characters.
static NSString *PresenceText(NSString *s) {
    s = [[s componentsSeparatedByCharactersInSet:NSCharacterSet.controlCharacterSet] componentsJoinedByString:@" "];
    s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!s.length) return @"";
    NSMutableString *out = [NSMutableString new];
    [s enumerateSubstringsInRange:NSMakeRange(0, s.length) options:NSStringEnumerationByComposedCharacterSequences
                       usingBlock:^(NSString *part, NSRange r, NSRange e, BOOL *stop) {
        if ([out lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + [part lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 128) *stop = YES;
        else [out appendString:part];
    }];
    if (out.length == 1) [out appendString:@" "];
    return out;
}
static void LogResult(NSString *event, const discordpp::ClientResult &r) {
    NSString *body = @(r.ResponseBody().c_str());
    NSData *data = [body dataUsingEncoding:NSUTF8StringEncoding];
    id response = data.length ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:NULL] : @"";
    YTMPLog(event, @{ @"success": @(r.Successful()), @"error_type": @((int)r.Type()), @"http_status": @((int)r.Status()),
                      @"error_code": @(r.ErrorCode()), @"error": @(r.Error().c_str()), @"response": response ?: body,
                      @"retryable": @(r.Retryable()), @"retry_after": @(r.RetryAfter()) });
}
static NSDictionary *TokenQuery(void) {
    return @{ (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
              (__bridge id)kSecAttrService: kTokenService, (__bridge id)kSecAttrAccount: kAccount };
}
static NSDictionary *TokenRead(void) {
    NSMutableDictionary *q = [TokenQuery() mutableCopy];
    q[(__bridge id)kSecReturnData] = @YES;
    q[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef value = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &value) != errSecSuccess) return nil;
    id result = [NSJSONSerialization JSONObjectWithData:CFBridgingRelease(value) options:0 error:NULL];
    return [result isKindOfClass:NSDictionary.class] ? result : nil;
}
static BOOL TokenWrite(NSDictionary *tokens) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:tokens options:0 error:NULL];
    if (!data) return NO;
    NSDictionary *attrs = @{ (__bridge id)kSecValueData: data,
                             (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly };
    OSStatus st = SecItemUpdate((__bridge CFDictionaryRef)TokenQuery(), (__bridge CFDictionaryRef)attrs);
    if (st == errSecItemNotFound) {
        NSMutableDictionary *item = [TokenQuery() mutableCopy];
        [item addEntriesFromDictionary:attrs];
        st = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    }
    return st == errSecSuccess;
}
static void TokenDelete(void) { SecItemDelete((__bridge CFDictionaryRef)TokenQuery()); }

/// Cover from the shared track model: only when it belongs to the song that is being reported.
static NSString *gCoverReason = @"";
static NSMutableDictionary<NSString *, NSString *> *gSearchedIDs;   // "title|artist" -> video id ("" = none)

static NSString *CurrentVideoID(IVLTrack *t);
static NSString *CoverKey(IVLTrack *t) { return [NSString stringWithFormat:@"%@|%@", t.title ?: @"", t.artist ?: @""]; }

/// Short, stable cover URL for Discord. Discord limits image URLs to 256 characters and
/// fetches them through its media proxy, so signed thumbnail URLs are avoided.
/// When the playing video id is unknown, a YouTube Music search fills it in (cached, async).
static NSString *CoverURL(NSString *title) {
    IVLPlaybackManager *m = [IVLPlaybackManager shared];
    IVLTrack *t = m.track;
    if (!t) { gCoverReason = @"no track"; return nil; }
    if (![t.title isEqualToString:title]) { gCoverReason = [NSString stringWithFormat:@"title mismatch (%@)", t.title ?: @""]; return nil; }

    // 1. album art on googleusercontent: drop the size/crop suffix, ask for a square 512px image
    NSURLComponents *art = [NSURLComponents componentsWithString:t.artworkURL ?: @""];
    NSString *host = art.host.lowercaseString;
    if ([art.scheme isEqualToString:@"https"] && ([host hasSuffix:@"googleusercontent.com"] || [host hasSuffix:@"ggpht.com"])) {
        NSString *path = art.percentEncodedPath ?: @"";
        NSRange eq = [path rangeOfString:@"=" options:NSBackwardsSearch];
        if (eq.location != NSNotFound) path = [path substringToIndex:eq.location];
        NSString *url = [NSString stringWithFormat:@"https://%@%@=w512-h512-l90-rj", art.host, path];
        if (url.length <= 256) { gCoverReason = @"album art"; return url; }
    }
    // 2. the video's standard thumbnail (always exists, short, no signature)
    NSString *vid = CurrentVideoID(t);
    if (vid.length == 11) { gCoverReason = @"video thumbnail"; return [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg", vid]; }
    gCoverReason = gSearchedIDs[CoverKey(t)] ? @"no video id (searching or not found)" : @"no video id";
    return nil;
}

/// Video id of the track: player, length-matched player video, or a cached YouTube Music search.
static NSString *CurrentVideoID(IVLTrack *t) {
    IVLPlaybackManager *m = [IVLPlaybackManager shared];
    NSString *vid = t.youtubeVideoID;
    if (vid.length != 11) vid = [m captionVideoIDForTrack:t];
    if (vid.length != 11) {
        if (!gSearchedIDs) gSearchedIDs = [NSMutableDictionary dictionary];
        NSString *key = CoverKey(t);
        NSString *cached = gSearchedIDs[key];
        if (cached.length == 11) vid = cached;
        else if (!cached) {
            gSearchedIDs[key] = @"";   // in flight / not found
            [[IVLLyricsService shared] youtubeVideoIDForTrack:t completion:^(NSString *found) {
                dispatch_async(dispatch_get_main_queue(), ^{ if (found.length == 11) gSearchedIDs[key] = found; });
            }];
        }
    }
    return vid.length == 11 ? vid : nil;
}

@interface IVLDiscord () {
    std::shared_ptr<discordpp::Client> client;
    BOOL ready, busy, published, inFlight, blockedPayload, ticking, omitArtwork;
    NSUInteger generation, metadataRevision;
    int payloadMode;
    NSTimeInterval nextAttempt, nextAuthAttempt, lastSend;
    NSDictionary *tokens;
    NSString *lastFingerprint, *sampleFingerprint;
    double sampleStart;
    NSTimer *timer;
}
@property (nonatomic, copy, readwrite) NSString *status;
@end

@implementation IVLDiscord

+ (BOOL)available { return IVLDiscordLoad(); }

+ (instancetype)shared {
    static IVLDiscord *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [self new]; });
    return s;
}

- (void)setStatus:(NSString *)status {
    _status = [status copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:IVLDiscordStatusDidChangeNotification object:self];
    });
}

- (instancetype)init {
    if ((self = [super init])) {
        if (![IVLDiscord available]) {
            _status = gDiscordLoadInfo.length
                ? [@"SDKの読み込みに失敗：" stringByAppendingString:gDiscordLoadInfo]
                : @"discord_partner_sdk.dylib が見つかりません（ivLyricsYTM.dylib と同じ場所に置いてください）";
            return self;
        }
        self.status = @"未連携";
        tokens = TokenRead();
        YTMPRememberSecret(Text(tokens[@"access"])); YTMPRememberSecret(Text(tokens[@"refresh"]));
        YTMPLog(@"startup", @{ @"app_id": kAccount, @"saved_token": @(tokens != nil) });
        client = std::make_shared<discordpp::Client>();
        client->SetApplicationId(IVL_DISCORD_APP_ID);
        client->SetEngineManagedAudioSession(true);
        client->AddLogCallback([](auto message, auto severity) {
            YTMPLog(@"sdk_warning", @{ @"severity": @((int)severity), @"message": @(message.c_str()) });
        }, discordpp::LoggingSeverity::Warning);
        client->SetStatusChangedCallback([self](auto state, auto error, int32_t detail) {
            YTMPLog(@"connection", @{ @"state": @(discordpp::Client::StatusToString(state).c_str()),
                                      @"error": @(discordpp::Client::ErrorToString(error).c_str()), @"detail": @(detail) });
            ready = state == discordpp::Client::Status::Ready;
            self.status = ready ? @"接続済み" : @"接続待ち";
            if (!ready) { published = NO; lastFingerprint = nil; }
            if (error != discordpp::Client::Error::None) {
                self.status = @"接続エラー：設定と通信を確認";
                nextAuthAttempt = NSDate.date.timeIntervalSince1970 + 30;
            }
        });
        client->SetTokenExpirationCallback([self]() { [self refresh]; });
        timer = [NSTimer timerWithTimeInterval:0.1 target:self selector:@selector(tick) userInfo:nil repeats:YES];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(resume) name:UIApplicationDidBecomeActiveNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(background) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [self resume];
    }
    return self;
}

- (BOOL)linked { return Text(tokens[@"access"]).length > 0; }
- (BOOL)enabled { return [IVLDiscord available] && [NSUserDefaults.standardUserDefaults boolForKey:kEnabledKey]; }
- (NSArray<NSURL *> *)logFiles {
    YTMPFlushLogs();
    NSMutableArray *files = [NSMutableArray array];
    NSURL *cur = YTMPLogFileURL();
    if ([NSFileManager.defaultManager fileExistsAtPath:cur.path]) [files addObject:cur];
    NSURL *prev = [[cur URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"discord.previous.jsonl"];
    if ([NSFileManager.defaultManager fileExistsAtPath:prev.path]) [files addObject:prev];
    return files;
}

- (void)connectToken {
    auto epoch = generation;
    client->UpdateToken(discordpp::AuthorizationTokenType::Bearer, UTF8(Text(tokens[@"access"])), [self, epoch](auto result) {
        LogResult(@"update_token", result);
        if (epoch != generation || ![self enabled]) return;
        if (result.Successful()) { self.status = @"接続中"; client->Connect(); }
        else self.status = @"認証エラー：再連携してください";
    });
}

- (void)acceptAccess:(NSString *)access refresh:(NSString *)refresh expires:(int32_t)seconds {
    YTMPRememberSecret(access); YTMPRememberSecret(refresh);
    tokens = @{ @"access": access, @"refresh": refresh, @"expiry": @(NSDate.date.timeIntervalSince1970 + MAX(0, seconds)) };
    self.status = TokenWrite(tokens) ? @"認証済み" : @"認証済み（保存失敗、次回は再連携）";
    [self connectToken];
}

- (void)refresh {
    if (busy || ![self enabled] || !Text(tokens[@"refresh"]).length) return;
    busy = YES;
    auto epoch = generation;
    client->RefreshToken(IVL_DISCORD_APP_ID, UTF8(Text(tokens[@"refresh"])),
                         [self, epoch](auto result, std::string access, std::string refresh, auto type, int32_t expires, std::string scope) {
        YTMPRememberSecret(@(access.c_str())); YTMPRememberSecret(@(refresh.c_str()));
        LogResult(@"refresh_token", result);
        if (epoch != generation) return;
        busy = NO;
        if (!result.Successful()) {
            self.status = @"認証更新失敗：再連携または通信を確認";
            nextAuthAttempt = NSDate.date.timeIntervalSince1970 + 60;
            return;
        }
        [self acceptAccess:@(access.c_str()) refresh:@(refresh.c_str()) expires:expires];
    });
}

- (void)resume {
    if (![self enabled] || busy) return;
    if (NSDate.date.timeIntervalSince1970 < nextAuthAttempt) return;
    if (!Text(tokens[@"access"]).length) { self.status = @"Discordと連携してください"; return; }
    if (Number(tokens[@"expiry"], 0) < NSDate.date.timeIntervalSince1970 + 120) [self refresh];
    else if (!ready) { nextAuthAttempt = NSDate.date.timeIntervalSince1970 + 30; [self connectToken]; }
}

- (void)login {
    if (![IVLDiscord available] || busy) return;
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:kEnabledKey];
    busy = YES; self.status = @"Discordの認証を待っています";
    blockedPayload = NO; payloadMode = 0; omitArtwork = NO; nextAttempt = 0; inFlight = NO;
    auto epoch = ++generation;
    auto verifier = client->CreateAuthorizationCodeVerifier();
    YTMPRememberSecret(@(verifier.Verifier().c_str()));
    YTMPLog(@"authorize_start", @{ @"scopes": @(discordpp::Client::GetDefaultPresenceScopes().c_str()) });
    discordpp::AuthorizationArgs args{};
    args.SetClientId(IVL_DISCORD_APP_ID);
    args.SetScopes(discordpp::Client::GetDefaultPresenceScopes());
    args.SetCodeChallenge(verifier.Challenge());
    client->Authorize(args, [self, epoch, verifier](auto result, auto code, auto redirect) {
        YTMPRememberSecret(@(code.c_str())); LogResult(@"authorize", result);
        if (epoch != generation) return;
        if (!result.Successful()) { busy = NO; self.status = @"認証キャンセルまたは失敗"; return; }
        client->GetToken(IVL_DISCORD_APP_ID, code, verifier.Verifier(), redirect,
                         [self, epoch](auto result, std::string access, std::string refresh, auto type, int32_t expires, std::string scope) {
            YTMPRememberSecret(@(access.c_str())); YTMPRememberSecret(@(refresh.c_str()));
            LogResult(@"get_token", result);
            if (epoch != generation) return;
            busy = NO;
            if (!result.Successful()) { self.status = @"トークン交換失敗：Public Client設定を確認"; return; }
            [self acceptAccess:@(access.c_str()) refresh:@(refresh.c_str()) expires:expires];
        });
    });
}

- (void)clear {
    if (ready && published) { client->ClearRichPresence(); YTMPLog(@"presence_clear", @{}); }
    published = NO; lastFingerprint = nil;
}

- (void)disable {
    if (![IVLDiscord available]) return;
    YTMPLog(@"sharing_disabled", @{});
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:kEnabledKey];
    ++generation; busy = NO; client->AbortAuthorize();
    if (ready && inFlight && !published) client->ClearRichPresence();
    [self clear]; client->Disconnect(); ready = NO; inFlight = NO;
    self.status = @"共有停止";
}

- (void)forget {
    if (![IVLDiscord available]) return;
    NSString *refresh = Text(tokens[@"refresh"]);
    [self disable];
    if (refresh.length) client->RevokeToken(IVL_DISCORD_APP_ID, UTF8(refresh), [](auto result) { LogResult(@"revoke_token", result); });
    TokenDelete(); tokens = nil;
    self.status = @"連携解除（保存情報を削除）";
}

- (BOOL)isPlaying:(NSDictionary *)info {
    MPNowPlayingPlaybackState state = MPNowPlayingInfoCenter.defaultCenter.playbackState;
    if (state == MPNowPlayingPlaybackStatePaused || state == MPNowPlayingPlaybackStateStopped || state == MPNowPlayingPlaybackStateInterrupted) return NO;
    double rate = Number(info[MPNowPlayingInfoPropertyPlaybackRate], -1);
    return rate >= 0 ? rate > 0 : state == MPNowPlayingPlaybackStatePlaying;
}

- (NSDictionary *)currentInfo { return [IVLLockScreen shared].originalInfo ?: MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo; }

- (void)background { if (![self isPlaying:[self currentInfo]]) [self clear]; }

- (void)retry {
    if (![IVLDiscord available]) return;
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:kEnabledKey];
    blockedPayload = NO; payloadMode = 0; omitArtwork = NO; nextAttempt = 0; nextAuthAttempt = 0;
    lastFingerprint = nil; self.status = @"再試行中";
    YTMPLog(@"manual_retry", @{});
    [self resume]; [self tick];
}

- (BOOL)coverEnabled {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:kCoverKey];
    return v ? [v boolValue] : YES;
}

- (void)setCoverEnabled:(BOOL)on {
    [NSUserDefaults.standardUserDefaults setBool:on forKey:kCoverKey];
    omitArtwork = NO; lastFingerprint = nil;
    YTMPLog(@"cover_setting", @{ @"enabled": @(on) });
    [self tick];
}

- (void)tick {
    if (ticking || !client) return;
    ticking = YES; discordpp::RunCallbacks(); ticking = NO;
    if (![self enabled]) return;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (!busy && Text(tokens[@"access"]).length && Number(tokens[@"expiry"], 0) < now + 120 && now >= nextAuthAttempt) {
        nextAuthAttempt = now + 60; [self refresh];
    }
    if (!ready) { if (!busy && now >= nextAuthAttempt) [self resume]; return; }
    NSDictionary *info = [self currentInfo];
    NSString *title = Text(info[MPMediaItemPropertyTitle]);
    if (!title.length || ![self isPlaying:info]) { [self clear]; return; }
    NSString *artist = Text(info[MPMediaItemPropertyArtist]);
    NSString *album = Text(info[MPMediaItemPropertyAlbumTitle]);
    double duration = MAX(0, Number(info[MPMediaItemPropertyPlaybackDuration], 0));
    double elapsed = MAX(0, Number(info[MPNowPlayingInfoPropertyElapsedPlaybackTime], 0));
    double rate = Number(info[MPNowPlayingInfoPropertyPlaybackRate], 1);
    NSString *fingerprint = [NSString stringWithFormat:@"%@\n%@\n%@\n%.1f\n%.2f", title, artist, album, duration, rate];
    if (![fingerprint isEqual:sampleFingerprint]) { sampleStart = now - elapsed / MAX(0.01, rate); sampleFingerprint = fingerprint; }
    double start = sampleStart;
    NSInteger interval = MAX(3, MIN(60, [IVLSettings integerForKey:IVLKeyDiscordInterval]));
    if (inFlight || blockedPayload || now < nextAttempt || now - lastSend < interval) return;

    NSString *image = ([self coverEnabled] && !omitArtwork) ? CoverURL(title) : nil;
    IVLTrack *track = [IVLPlaybackManager shared].track;
    NSString *vid = [track.title isEqualToString:title] ? CurrentVideoID(track) : nil;
    NSString *songURL = vid ? [NSString stringWithFormat:@"https://music.youtube.com/watch?v=%@", vid] : nil;
    NSString *name = [[IVLSettings objectForKey:IVLKeyDiscordName] description];
    if (!name.length) name = @"YouTube Music iOS";
    // tooltip of the cover image: tweak version and iOS version, e.g. "v1.0.0 iOS 26.0.1"
    NSString *tooltip = [NSString stringWithFormat:@"v%s iOS %@", IVL_VERSION, UIDevice.currentDevice.systemVersion];
    BOOL songButton = [IVLSettings boolForKey:IVLKeyDiscordSongButton] && songURL;
    NSString *github = [[IVLSettings objectForKey:IVLKeyDiscordGitHubURL] description];
    BOOL githubButton = [IVLSettings boolForKey:IVLKeyDiscordGitHubButton] && [github hasPrefix:@"https://"];
    // everything that is shown is part of the fingerprint: changes (cover found later, settings) trigger a resend
    fingerprint = [fingerprint stringByAppendingFormat:@"\n%@\n%@\n%@\n%d%d%@", image ?: @"", name, songURL ?: @"", songButton, githubButton, github ?: @""];
    if (published && [fingerprint isEqual:lastFingerprint]) return;

    discordpp::Activity activity{};
    activity.SetType(payloadMode < 2 ? discordpp::ActivityTypes::Listening : discordpp::ActivityTypes::Playing);
    // "Listening to <name>" (Discord shows the application name when the name is not accepted)
    activity.SetName(UTF8(PresenceText(name)));
    activity.SetDetails(UTF8(PresenceText(title)));
    if (songURL && payloadMode == 0) activity.SetDetailsUrl(UTF8(songURL));
    if (PresenceText(artist).length) activity.SetState(UTF8(PresenceText(artist)));
    if (image.length) {
        discordpp::ActivityAssets assets{};
        assets.SetLargeImage(UTF8(image));
        assets.SetLargeText(UTF8(PresenceText(tooltip)));
        if (songURL) assets.SetLargeUrl(UTF8(songURL));
        activity.SetAssets(assets);
    }
    // up to two buttons (labels max 32 characters); others see them, the sender usually does not
    if (payloadMode < 2) {
        if (songButton) {
            discordpp::ActivityButton b{};
            b.SetLabel("Listen on YouTube Music");
            b.SetUrl(UTF8(songURL));
            activity.AddButton(b);
        }
        if (githubButton) {
            discordpp::ActivityButton b{};
            b.SetLabel("ivLyrics on GitHub");
            b.SetUrl(UTF8(github));
            activity.AddButton(b);
        }
    }
    BOOL withTimes = payloadMode == 0 && duration > 0 && elapsed <= duration && fabs(rate - 1) < 0.001;
    if (withTimes) {
        discordpp::ActivityTimestamps times{};
        times.SetStart((uint64_t)(MAX(0, start) * 1000));
        times.SetEnd((uint64_t)(MAX(0, start + duration) * 1000));
        activity.SetTimestamps(times);
    }
    auto epoch = generation;
    auto revision = metadataRevision;
    YTMPLog(@"presence_send", @{ @"mode": @(payloadMode), @"details": PresenceText(title), @"state": PresenceText(artist),
                                 @"duration": @(duration), @"elapsed": @(elapsed), @"timestamps": @(withTimes), @"image": image ?: @"", @"image_source": gCoverReason ?: @"",
                                 @"name": name, @"song_url": songURL ?: @"", @"buttons": @((songButton ? 1 : 0) + (githubButton ? 1 : 0)), @"interval": @(interval) });
    inFlight = YES; lastSend = now;
    client->UpdateRichPresence(activity, [self, epoch, revision, fingerprint, image](auto result) {
        LogResult(@"presence_result", result);
        if (epoch != generation) return;
        inFlight = NO;
        NSDictionary *current = [self currentInfo];
        if (![self enabled] || ![self isPlaying:current] || !Text(current[MPMediaItemPropertyTitle]).length) {
            client->ClearRichPresence(); published = NO; return;
        }
        if (result.Successful()) {
            published = YES;
            self.status = payloadMode == 2 ? @"共有中（互換表示）" : @"共有中";
            if (revision == metadataRevision) lastFingerprint = fingerprint;
            return;
        }
        int http = (int)result.Status();
        NSString *body = @(result.ResponseBody().c_str());
        BOOL invalidPayload = http == 400 || result.ErrorCode() == 50035;
        BOOL mentionsTime = [body.lowercaseString containsString:@"timestamps"];
        if (invalidPayload && image.length && !mentionsTime && !omitArtwork) {
            omitArtwork = YES; lastFingerprint = nil; nextAttempt = NSDate.date.timeIntervalSince1970 + 15;
            self.status = @"画像なしで再試行";
        } else if (invalidPayload && payloadMode < 2) {
            ++payloadMode; nextAttempt = NSDate.date.timeIntervalSince1970 + 15;
            self.status = @"送信内容を簡略化して再試行";
        } else if (http == 401 || http == 403 || http == 400) {
            blockedPayload = YES;
            self.status = [NSString stringWithFormat:@"更新失敗 HTTP %d / code %d：ログを確認", http, result.ErrorCode()];
        } else {
            double delay = http == 429 ? MAX(30, Number(@(result.RetryAfter()), 30)) : 30;
            nextAttempt = NSDate.date.timeIntervalSince1970 + delay;
            self.status = [NSString stringWithFormat:@"更新失敗 HTTP %d / code %d：再試行待ち", http, result.ErrorCode()];
        }
    });
}

- (void)noteMetadata:(NSDictionary *)info {
    if (!client) return;
    ++metadataRevision;
    double now = NSDate.date.timeIntervalSince1970;
    double elapsed = Number(info[MPNowPlayingInfoPropertyElapsedPlaybackTime], -1);
    double rate = Number(info[MPNowPlayingInfoPropertyPlaybackRate], 1);
    double duration = MAX(0, Number(info[MPMediaItemPropertyPlaybackDuration], 0));
    NSString *fingerprint = [NSString stringWithFormat:@"%@\n%@\n%@\n%.1f\n%.2f", Text(info[MPMediaItemPropertyTitle]),
                             Text(info[MPMediaItemPropertyArtist]), Text(info[MPMediaItemPropertyAlbumTitle]), duration, rate];
    if (elapsed >= 0 && rate > 0 && (![fingerprint isEqual:sampleFingerprint] || fabs((now - elapsed / rate) - sampleStart) > 3)) {
        sampleStart = now - elapsed / rate; sampleFingerprint = fingerprint; lastFingerprint = nil;
    }
    [self tick];
}

@end

#else   // built without the Discord Social SDK

@implementation IVLDiscord
+ (BOOL)available { return NO; }
+ (instancetype)shared {
    static IVLDiscord *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [self new]; });
    return s;
}
- (NSString *)status { return @"このビルドはDiscord非対応（SDKなしでビルド）"; }
- (BOOL)linked { return NO; }
- (BOOL)enabled { return NO; }
- (void)login {}
- (void)retry {}
- (void)disable {}
- (void)forget {}
- (BOOL)coverEnabled { return NO; }
- (void)setCoverEnabled:(BOOL)on {}
- (NSArray<NSURL *> *)logFiles { return @[]; }
- (void)noteMetadata:(NSDictionary *)info {}
@end

#endif
