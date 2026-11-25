#import "IVLScrobbler.h"
#import "IVLPlaybackManager.h"
#import "IVLRemoteControl.h"
#import "IVLLyricsService.h"
#import "IVLSettings.h"
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#import <UIKit/UIKit.h>

NSNotificationName const IVLScrobblerDidChangeNotification = @"IVLScrobblerDidChangeNotification";

static NSString *const kLastfmAPI = @"https://ws.audioscrobbler.com/2.0/";
static NSString *const kLBAPI = @"https://api.listenbrainz.org/1";
static NSString *const kKeychainService = @"ivLyrics.scrobble";

#pragma mark - Keychain (session key / token)

static NSString *IVLKeychainGet(NSString *account) {
    NSDictionary *q = @{ (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword, (__bridge id)kSecAttrService: kKeychainService,
                         (__bridge id)kSecAttrAccount: account, (__bridge id)kSecReturnData: @YES, (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne };
    CFTypeRef v = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &v) != errSecSuccess) return nil;
    return [[NSString alloc] initWithData:CFBridgingRelease(v) encoding:NSUTF8StringEncoding];
}

static void IVLKeychainSet(NSString *account, NSString *value) {
    NSDictionary *key = @{ (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword, (__bridge id)kSecAttrService: kKeychainService,
                           (__bridge id)kSecAttrAccount: account };
    SecItemDelete((__bridge CFDictionaryRef)key);
    if (!value.length) return;
    NSMutableDictionary *item = [key mutableCopy];
    item[(__bridge id)kSecValueData] = [value dataUsingEncoding:NSUTF8StringEncoding];
    item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    SecItemAdd((__bridge CFDictionaryRef)item, NULL);
}

static NSString *IVLMD5(NSString *s) {
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char out[CC_MD5_DIGEST_LENGTH];
    CC_MD5(d.bytes, (CC_LONG)d.length, out);
    NSMutableString *h = [NSMutableString string];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [h appendFormat:@"%02x", out[i]];
    return h;
}

static NSString *IVLFormEncode(NSDictionary<NSString *, NSString *> *params) {
    NSMutableCharacterSet *ok = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [ok addCharactersInString:@"-._~"];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *k in params) {
        [parts addObject:[NSString stringWithFormat:@"%@=%@", [k stringByAddingPercentEncodingWithAllowedCharacters:ok],
                          [params[k] stringByAddingPercentEncodingWithAllowedCharacters:ok]]];
    }
    return [parts componentsJoinedByString:@"&"];
}

@interface IVLScrobbler ()
@property (nonatomic, copy, readwrite) NSString *lastfmStatus;
@property (nonatomic, copy, readwrite) NSString *listenbrainzStatus;
@end

@implementation IVLScrobbler {
    NSTimer *_timer;
    NSString *_key;            // current song
    NSDictionary *_song;       // {artist, track, album, duration, start}
    double _listened;
    BOOL _scrobbled, _nowPlayingSent;
    NSMutableArray<NSDictionary *> *_queue;   // pending scrobbles {service, artist, track, album, duration, start}
    BOOL _flushing;
}

+ (instancetype)shared {
    static IVLScrobbler *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [self new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lastfmStatus = @"";
        _listenbrainzStatus = @"";
    }
    return self;
}

- (NSString *)queuePath {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [base stringByAppendingPathComponent:@"ivLyricsYTM/scrobble-queue.json"];
}

- (void)saveQueue {
    [[NSFileManager defaultManager] createDirectoryAtPath:[[self queuePath] stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSJSONSerialization dataWithJSONObject:_queue options:0 error:nil] writeToFile:[self queuePath] atomically:YES];
}

- (NSUInteger)pending { return _queue.count; }

- (void)changed {
    dispatch_async(dispatch_get_main_queue(), ^{ [[NSNotificationCenter defaultCenter] postNotificationName:IVLScrobblerDidChangeNotification object:self]; });
}

- (void)start {
    if (_timer) return;
    NSData *d = [NSData dataWithContentsOfFile:[self queuePath]];
    id json = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    _queue = [json isKindOfClass:[NSArray class]] ? [json mutableCopy] : [NSMutableArray array];
    self.lastfmStatus = self.lastfmLoggedIn ? [NSString stringWithFormat:@"%@ でログイン中", [IVLSettings objectForKey:IVLKeyLastfmUser] ?: @""] : @"未ログイン";
    self.listenbrainzStatus = [IVLKeychainGet(@"listenbrainz") length] ? @"トークン設定済み" : @"未設定";
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    _timer.tolerance = 0.3;
    [self flushQueue];
}

- (BOOL)lastfmLoggedIn { return IVLKeychainGet(@"lastfm-session").length > 0; }
- (BOOL)lastfmOn { return [IVLSettings boolForKey:IVLKeyLastfmEnabled] && self.lastfmLoggedIn; }
- (BOOL)lbOn { return [IVLSettings boolForKey:IVLKeyListenBrainzEnabled] && IVLKeychainGet(@"listenbrainz").length; }

#pragma mark - Tracking

- (void)tick {
    if (![self lastfmOn] && ![self lbOn]) return;
    IVLTrack *t = [IVLPlaybackManager shared].track;
    if (!t.title.length) return;
    NSString *key = t.videoID ?: t.title;
    if (![key isEqualToString:_key]) {
        _key = key;
        _listened = 0;
        _scrobbled = NO;
        _nowPlayingSent = NO;
        // YouTube "Artist - Topic" channels and "(Official Video)" titles are cleaned like the lyrics search
        _song = @{ @"artist": [IVLLyricsService cleanArtist:t.artist ?: @""], @"track": [IVLLyricsService cleanTitle:t.title],
                   @"duration": @((NSInteger)llround(t.duration)), @"start": @((long long)NSDate.date.timeIntervalSince1970) };
    }
    [[IVLPlaybackManager shared] rawTimeMs];
    if (![IVLRemoteControl isPlaying]) return;
    _listened += 1.0;
    if (!_nowPlayingSent && _listened >= 3 && [_song[@"artist"] length]) { _nowPlayingSent = YES; [self sendNowPlaying:_song]; }
    double dur = [_song[@"duration"] doubleValue];
    if (!_scrobbled && dur >= 30 && _listened >= MIN(dur / 2.0, 240.0) && [_song[@"artist"] length]) {
        _scrobbled = YES;
        if ([self lastfmOn]) { NSMutableDictionary *e = [_song mutableCopy]; e[@"service"] = @"lastfm"; [_queue addObject:e]; }
        if ([self lbOn]) { NSMutableDictionary *e = [_song mutableCopy]; e[@"service"] = @"listenbrainz"; [_queue addObject:e]; }
        [self saveQueue];
        [self flushQueue];
    }
}

#pragma mark - Last.fm

- (void)lastfmCall:(NSDictionary *)params completion:(void (^)(NSDictionary *json, NSInteger status))completion {
    NSString *apiKey = [IVLSettings objectForKey:IVLKeyLastfmKey] ?: @"";
    NSString *secret = IVLKeychainGet(@"lastfm-secret") ?: @"";
    NSMutableDictionary *p = [params mutableCopy];
    p[@"api_key"] = apiKey;
    NSString *sk = IVLKeychainGet(@"lastfm-session");
    if (sk.length && !p[@"password"]) p[@"sk"] = sk;
    NSMutableString *sigBase = [NSMutableString string];
    for (NSString *k in [p.allKeys sortedArrayUsingSelector:@selector(compare:)]) [sigBase appendFormat:@"%@%@", k, p[k]];
    [sigBase appendString:secret];
    p[@"api_sig"] = IVLMD5(sigBase);
    p[@"format"] = @"json";
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kLastfmAPI]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [IVLFormEncode(p) dataUsingEncoding:NSUTF8StringEncoding];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        NSInteger st = [r isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)r).statusCode : 0;
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        completion([json isKindOfClass:[NSDictionary class]] ? json : nil, st);
    }] resume];
}

- (void)lastfmLoginWithUser:(NSString *)user password:(NSString *)password completion:(void (^)(BOOL, NSString *))completion {
    if (![[IVLSettings objectForKey:IVLKeyLastfmKey] length] || !IVLKeychainGet(@"lastfm-secret").length) {
        completion(NO, @"API キーと共有シークレットを先に入力してください");
        return;
    }
    [self lastfmCall:@{ @"method": @"auth.getMobileSession", @"username": user ?: @"", @"password": password ?: @"" } completion:^(NSDictionary *json, NSInteger status) {
        NSString *sk = json[@"session"][@"key"];
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([sk isKindOfClass:[NSString class]] && sk.length) {
                IVLKeychainSet(@"lastfm-session", sk);
                [IVLSettings setObject:json[@"session"][@"name"] ?: user forKey:IVLKeyLastfmUser];
                self.lastfmStatus = [NSString stringWithFormat:@"%@ でログイン中", json[@"session"][@"name"] ?: user];
                [self changed];
                completion(YES, self.lastfmStatus);
            } else {
                NSString *msg = [json[@"message"] description] ?: [NSString stringWithFormat:@"HTTP %ld", (long)status];
                self.lastfmStatus = [@"ログイン失敗：" stringByAppendingString:msg];
                [self changed];
                completion(NO, msg);
            }
        });
    }];
}

- (void)lastfmLogout {
    IVLKeychainSet(@"lastfm-session", nil);
    [IVLSettings setObject:nil forKey:IVLKeyLastfmUser];
    self.lastfmStatus = @"未ログイン";
    [self changed];
}

#pragma mark - ListenBrainz

- (NSMutableURLRequest *)lbRequest:(NSString *)path body:(NSDictionary *)body {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[kLBAPI stringByAppendingString:path]]];
    [req setValue:[@"Token " stringByAppendingString:IVLKeychainGet(@"listenbrainz") ?: @""] forHTTPHeaderField:@"Authorization"];
    if (body) {
        req.HTTPMethod = @"POST";
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    }
    return req;
}

- (void)verifyListenBrainz:(void (^)(BOOL, NSString *))completion {
    [[[NSURLSession sharedSession] dataTaskWithRequest:[self lbRequest:@"/validate-token" body:nil] completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        BOOL ok = [json isKindOfClass:[NSDictionary class]] && [json[@"valid"] boolValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.listenbrainzStatus = ok ? [NSString stringWithFormat:@"%@ として送信", json[@"user_name"] ?: @"?"] : @"トークンが無効です";
            [self changed];
            completion(ok, self.listenbrainzStatus);
        });
    }] resume];
}

static NSDictionary *IVLLBPayload(NSDictionary *s, BOOL withTime) {
    NSMutableDictionary *meta = [@{ @"artist_name": s[@"artist"] ?: @"", @"track_name": s[@"track"] ?: @"" } mutableCopy];
    NSMutableDictionary *info = [@{ @"media_player": @"YouTube Music", @"submission_client": @"ivLyricsYTM", @"music_service": @"music.youtube.com" } mutableCopy];
    if ([s[@"duration"] integerValue] > 0) info[@"duration_ms"] = @([s[@"duration"] integerValue] * 1000);
    meta[@"additional_info"] = info;
    NSMutableDictionary *listen = [@{ @"track_metadata": meta } mutableCopy];
    if (withTime) listen[@"listened_at"] = s[@"start"];
    return listen;
}

#pragma mark - Sending

- (void)sendNowPlaying:(NSDictionary *)s {
    if ([self lastfmOn]) {
        NSMutableDictionary *p = [@{ @"method": @"track.updateNowPlaying", @"artist": s[@"artist"], @"track": s[@"track"] } mutableCopy];
        if ([s[@"duration"] integerValue] > 0) p[@"duration"] = [s[@"duration"] description];
        [self lastfmCall:p completion:^(NSDictionary *json, NSInteger status) {
            if (status == 200) { self.lastfmStatus = [NSString stringWithFormat:@"再生中を送信：%@", s[@"track"]]; [self changed]; }
        }];
    }
    if ([self lbOn]) {
        NSURLRequest *req = [self lbRequest:@"/submit-listens" body:@{ @"listen_type": @"playing_now", @"payload": @[IVLLBPayload(s, NO)] }];
        [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {}] resume];
    }
}

- (void)flushQueue {
    if (_flushing || !_queue.count) return;
    _flushing = YES;
    NSDictionary *e = _queue.firstObject;
    void (^done)(BOOL ok, BOOL drop, NSString *status) = ^(BOOL ok, BOOL drop, NSString *status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_flushing = NO;
            if (ok || drop) { [self->_queue removeObjectAtIndex:0]; [self saveQueue]; }
            if ([e[@"service"] isEqual:@"lastfm"]) self.lastfmStatus = status; else self.listenbrainzStatus = status;
            [self changed];
            if (ok || drop) [self flushQueue];
            else dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self flushQueue]; });
        });
    };
    if ([e[@"service"] isEqual:@"lastfm"]) {
        if (!self.lastfmLoggedIn) { done(NO, YES, @"未ログインのため破棄"); return; }
        NSMutableDictionary *p = [@{ @"method": @"track.scrobble", @"artist": e[@"artist"], @"track": e[@"track"], @"timestamp": [e[@"start"] description] } mutableCopy];
        if ([e[@"duration"] integerValue] > 0) p[@"duration"] = [e[@"duration"] description];
        [self lastfmCall:p completion:^(NSDictionary *json, NSInteger status) {
            BOOL ok = status == 200 && json[@"scrobbles"];
            NSInteger err = [json[@"error"] integerValue];
            // 9 = invalid session, 10/26 = bad key: drop; others (network, 11/16 service offline) retry
            BOOL drop = err == 9 || err == 10 || err == 26 || err == 6;
            done(ok, drop, ok ? [NSString stringWithFormat:@"スクロブル済み：%@", e[@"track"]] : [NSString stringWithFormat:@"送信失敗（%@）", json[@"message"] ?: @(status)]);
        }];
    } else {
        NSURLRequest *req = [self lbRequest:@"/submit-listens" body:@{ @"listen_type": @"single", @"payload": @[IVLLBPayload(e, YES)] }];
        [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *er) {
            NSInteger st = [r isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)r).statusCode : 0;
            done(st == 200, st == 400 || st == 401, st == 200 ? [NSString stringWithFormat:@"送信済み：%@", e[@"track"]] : [NSString stringWithFormat:@"送信失敗（HTTP %ld）", (long)st]);
        }] resume];
    }
}

@end

#pragma mark - setters used by the settings screen

void IVLScrobblerSetSecret(NSString *account, NSString *value);
void IVLScrobblerSetSecret(NSString *account, NSString *value) { IVLKeychainSet(account, value); }
