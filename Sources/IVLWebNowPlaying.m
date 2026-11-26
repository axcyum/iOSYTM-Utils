// WebNowPlaying protocol: https://github.com/keifufu/WebNowPlaying (src/extension/sw/socket.ts, content.ts)
// The adapter is the WebSocket server; this tweak plays the role of the browser extension.

#import "IVLWebNowPlaying.h"
#import "IVLPlaybackManager.h"
#import "IVLRemoteControl.h"
#import "IVLLockScreen.h"
#import "IVLSettings.h"
#import <Network/Network.h>
#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>

NSNotificationName const IVLWebNowPlayingStatusDidChangeNotification = @"IVLWebNowPlayingStatusDidChangeNotification";

// rev3 message types
enum { WNP_PLAYER_ADDED = 0, WNP_PLAYER_UPDATED = 1, WNP_PLAYER_REMOVED = 2, WNP_EVENT_RESULT = 3, WNP_USE_DESKTOP_PLAYERS = 4 };
// rev3 player states / repeat flags / rating systems
enum { WNP_PLAYING = 0, WNP_PAUSED = 1, WNP_STOPPED = 2 };
static const int kPlayerID = 1;

@interface IVLWebNowPlaying ()
@property (nonatomic, copy, readwrite) NSString *status;
@end

@implementation IVLWebNowPlaying {
    dispatch_queue_t _q;
    nw_connection_t _conn;
    NSString *_revision;              // nil until the adapter announced itself
    NSTimer *_tick;                   // main thread
    NSMutableDictionary *_cache;      // last values sent (rev legacy/1/2) or last player line (rev3)
    BOOL _playerAdded;
    NSString *_lastCoverKey;
    NSUInteger _attempt;
    NSUInteger _generation;
    long long _createdAt;
}

+ (instancetype)shared {
    static IVLWebNowPlaying *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [self new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _q = dispatch_queue_create("ivlyrics.wnp", DISPATCH_QUEUE_SERIAL);
        _status = @"";
        _createdAt = (long long)(NSDate.date.timeIntervalSince1970 * 1000);
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(settingsChanged:) name:IVLSettingsDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillEnterForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self syncTimer];
            [self reconnect];
        });
    }
    return self;
}

- (void)syncTimer {
    BOOL on = [IVLSettings boolForKey:IVLKeyWNPEnabled];
    if (on && !_tick) {
        _tick = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(push) userInfo:nil repeats:YES];
    } else if (!on && _tick) {
        [_tick invalidate];
        _tick = nil;
    }
}

- (void)appDidEnterBackground {
    // Never keep retrying TCP connections while backgrounded and not playing
    if (![IVLRemoteControl isPlaying]) {
        dispatch_async(_q, ^{
            self->_generation++;
            [self closeLocked];
        });
    }
}

- (void)appWillEnterForeground {
    if (![IVLSettings boolForKey:IVLKeyWNPEnabled]) return;
    dispatch_async(_q, ^{
        if (!self->_conn) {
            self->_generation++;
            self->_attempt = 0;
            [self openLocked];
        }
    });
}

- (void)setStatusText:(NSString *)s {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.status = s;
        [[NSNotificationCenter defaultCenter] postNotificationName:IVLWebNowPlayingStatusDidChangeNotification object:self];
    });
}

- (void)settingsChanged:(NSNotification *)n {
    NSString *k = n.object;
    if ([k isEqualToString:IVLKeyWNPEnabled] || [k isEqualToString:IVLKeyWNPHost] || [k isEqualToString:IVLKeyWNPPort]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self syncTimer]; });
        [self reconnect];
    }
}

#pragma mark - Connection

- (void)reconnect {
    dispatch_async(_q, ^{
        self->_generation++;
        self->_attempt = 0;
        [self closeLocked];
        if (![IVLSettings boolForKey:IVLKeyWNPEnabled]) { [self setStatusText:@"オフ"]; return; }
        [self openLocked];
    });
}

- (void)closeLocked {
    if (_conn) {
        nw_connection_set_state_changed_handler(_conn, NULL);
        nw_connection_cancel(_conn);
        _conn = nil;
    }
    _revision = nil;
    _cache = [NSMutableDictionary dictionary];
    _playerAdded = NO;
    _lastCoverKey = nil;
}

- (void)openLocked {
    NSString *host = [[IVLSettings objectForKey:IVLKeyWNPHost] description] ?: @"";
    host = [host stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSInteger port = [IVLSettings integerForKey:IVLKeyWNPPort];
    if (!host.length) { [self setStatusText:@"PCのIPアドレスを設定してください"]; return; }
    if (port <= 0 || port > 65535) port = 8974;

    NSString *url = [NSString stringWithFormat:@"ws://%@:%ld", [host containsString:@":"] ? [NSString stringWithFormat:@"[%@]", host] : host, (long)port];
    nw_endpoint_t ep = nw_endpoint_create_url(url.UTF8String);
    if (!ep) { [self setStatusText:@"アドレスが不正です"]; return; }
    nw_parameters_t params = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_protocol_options_t ws = nw_ws_create_options(nw_ws_version_13);
    nw_ws_options_set_auto_reply_ping(ws, true);
    nw_protocol_stack_t stack = nw_parameters_copy_default_protocol_stack(params);
    nw_protocol_stack_prepend_application_protocol(stack, ws);

    nw_connection_t c = nw_connection_create(ep, params);
    _conn = c;
    NSUInteger gen = _generation;
    nw_connection_set_queue(c, _q);
    [self setStatusText:[NSString stringWithFormat:@"%@ に接続中…", url]];
    nw_connection_set_state_changed_handler(c, ^(nw_connection_state_t state, nw_error_t error) {
        if (gen != self->_generation) return;
        switch (state) {
            case nw_connection_state_ready: {
                self->_attempt = 0;
                [self setStatusText:@"接続済み（アダプターの応答待ち）"];
                [self receiveOn:c generation:gen];
                // adapters older than WNP for Rainmeter 0.5 say nothing: assume legacy after 1s
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), self->_q, ^{
                    if (gen == self->_generation && !self->_revision && self->_conn == c) {
                        self->_revision = @"legacy";
                        [self setStatusText:@"接続済み（legacy）"];
                    }
                });
                break;
            }
            case nw_connection_state_waiting:
            case nw_connection_state_failed: {
                int code = error ? nw_error_get_error_code(error) : 0;
                [self setStatusText:[NSString stringWithFormat:@"接続できません（%d）。再試行します", code]];
                [self scheduleRetryFrom:c generation:gen];
                break;
            }
            case nw_connection_state_cancelled:
                break;
            default: break;
        }
    });
    nw_connection_start(c);
}

- (void)scheduleRetryFrom:(nw_connection_t)c generation:(NSUInteger)gen {
    if (c != _conn) return;
    nw_connection_set_state_changed_handler(c, NULL);
    nw_connection_cancel(c);
    _conn = nil;
    _revision = nil;
    _playerAdded = NO;
    _cache = [NSMutableDictionary dictionary];
    if (![IVLSettings boolForKey:IVLKeyWNPEnabled]) {
        [self setStatusText:@"オフ"];
        return;
    }
    // Cap consecutive retries at 5 so unreachable hosts never spin up thousands of TCP sockets
    static const NSUInteger kMaxRetries = 5;
    if (_attempt >= kMaxRetries) {
        [self setStatusText:@"接続できません（設定から再接続）"];
        return;
    }
    double delay = MIN(60.0, 5.0 * pow(2.0, (double)_attempt));
    _attempt++;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _q, ^{
        if (gen == self->_generation && !self->_conn && [IVLSettings boolForKey:IVLKeyWNPEnabled]) [self openLocked];
    });
}

- (void)receiveOn:(nw_connection_t)c generation:(NSUInteger)gen {
    nw_connection_receive_message(c, ^(dispatch_data_t content, nw_content_context_t context, bool complete, nw_error_t error) {
        if (gen != self->_generation || c != self->_conn) return;
        if (error) { [self scheduleRetryFrom:c generation:gen]; return; }
        nw_protocol_metadata_t md = context ? nw_content_context_copy_protocol_metadata(context, nw_protocol_copy_ws_definition()) : nil;
        nw_ws_opcode_t op = md ? nw_ws_metadata_get_opcode(md) : nw_ws_opcode_text;
        if (op == nw_ws_opcode_close) { [self scheduleRetryFrom:c generation:gen]; return; }
        if (content && op == nw_ws_opcode_text) {
            NSMutableData *buf = [NSMutableData data];
            dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset, const void *bytes, size_t size) {
                [buf appendBytes:bytes length:size]; return true;
            });
            NSString *msg = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding];
            if (msg.length) [self handleMessage:msg];
        }
        [self receiveOn:c generation:gen];
    });
}

- (void)sendText:(NSString *)text {
    nw_connection_t c = _conn;
    if (!c || !text.length) return;
    [self sendData:[text dataUsingEncoding:NSUTF8StringEncoding] opcode:nw_ws_opcode_text];
}

- (void)sendData:(NSData *)data opcode:(nw_ws_opcode_t)opcode {
    nw_connection_t c = _conn;
    if (!c || !data) return;
    nw_protocol_metadata_t md = nw_ws_create_metadata(opcode);
    nw_content_context_t ctx = nw_content_context_create("wnp");
    nw_content_context_set_metadata_for_protocol(ctx, md);
    NSData *copy = [data copy];
    dispatch_data_t d = dispatch_data_create(copy.bytes, copy.length, _q, ^{ (void)copy; });
    nw_connection_send(c, d, ctx, true, ^(nw_error_t e) {});
}

#pragma mark - Incoming

- (void)handleMessage:(NSString *)msg {
    if (!_revision) {
        if ([msg hasPrefix:@"ADAPTER_VERSION "]) {
            // "ADAPTER_VERSION <version>;WNPLIB_REVISION <revision>"
            NSArray *parts = [msg componentsSeparatedByString:@";"];
            NSString *rev = parts.count > 1 ? [[parts[1] componentsSeparatedByString:@" "] lastObject] : @"1";
            _revision = rev.length ? rev : @"1";
            if ([_revision isEqualToString:@"2"]) [self sendText:@"USE_NATIVE_APIS false"];
            if ([_revision isEqualToString:@"3"]) [self sendText:[NSString stringWithFormat:@"%d 0", WNP_USE_DESKTOP_PLAYERS]];
            NSString *ver = [[parts.firstObject componentsSeparatedByString:@" "] lastObject] ?: @"";
            [self setStatusText:[NSString stringWithFormat:@"接続済み（アダプター %@ / rev %@）", ver, _revision]];
        } else {
            _revision = @"legacy";
            [self setStatusText:@"接続済み（legacy）"];
            if ([msg hasPrefix:@"Version:"]) return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ [self push]; });
        return;
    }
    if (![IVLSettings boolForKey:IVLKeyWNPControl]) {
        if ([_revision isEqualToString:@"3"]) {
            NSArray *p = [msg componentsSeparatedByString:@" "];
            if (p.count >= 2) [self sendText:[NSString stringWithFormat:@"%d %@ 2", WNP_EVENT_RESULT, p[1]]];
        }
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ [self execute:msg]; });
}

/// Runs on the main thread.
- (void)execute:(NSString *)msg {
    NSString *rev = _revision;
    BOOL ok = NO;
    NSString *eventID = nil;
    if ([rev isEqualToString:@"3"]) {
        // "<playerId> <eventId> <type> <data>"
        NSArray<NSString *> *p = [msg componentsSeparatedByString:@" "];
        if (p.count < 3) return;
        eventID = p[1];
        int type = p[2].intValue;
        NSString *data = p.count > 3 ? p[3] : @"";
        switch (type) {
            case 0: ok = data.intValue == WNP_PLAYING ? [IVLRemoteControl play] : [IVLRemoteControl pause]; break;
            case 1: ok = [IVLRemoteControl previous]; break;
            case 2: ok = [IVLRemoteControl next]; break;
            case 3: [[IVLPlaybackManager shared] seekToMs:(NSInteger)(data.doubleValue * 1000) + [self offsetMs]]; ok = YES; break;
            default: ok = NO; break;   // volume, rating, repeat, shuffle: not controllable from here
        }
    } else {
        // legacy "playpause" / rev1+2 "TOGGLE_PLAYING", "SET_POSITION 12:5.3"...
        NSArray<NSString *> *p = [msg.uppercaseString componentsSeparatedByString:@" "];
        NSString *cmd = p.firstObject ?: @"";
        NSString *data = p.count > 1 ? p[1] : @"";
        if ([cmd isEqualToString:@"PLAYPAUSE"] || [cmd isEqualToString:@"TOGGLE_PLAYING"]) ok = [IVLRemoteControl togglePlayPause];
        else if ([cmd isEqualToString:@"PLAY"]) ok = [IVLRemoteControl play];
        else if ([cmd isEqualToString:@"PAUSE"]) ok = [IVLRemoteControl pause];
        else if ([cmd isEqualToString:@"NEXT"]) ok = [IVLRemoteControl next];
        else if ([cmd isEqualToString:@"PREVIOUS"]) ok = [IVLRemoteControl previous];
        else if ([cmd isEqualToString:@"SET_POSITION"] || [cmd isEqualToString:@"SETPOSITION"]) {
            double sec = [[data componentsSeparatedByString:@":"].firstObject doubleValue];
            [[IVLPlaybackManager shared] seekToMs:(NSInteger)(sec * 1000) + [self offsetMs]];
            ok = YES;
        }
    }
    if (eventID) {
        NSString *reply = [NSString stringWithFormat:@"%d %@ %d", WNP_EVENT_RESULT, eventID, ok ? 1 : 2];
        dispatch_async(_q, ^{ [self sendText:reply]; });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self push]; });
}

/// seekToMs: takes lyric time; WNP positions are player time
- (NSInteger)offsetMs { return [IVLSettings integerForKey:IVLKeyGlobalOffset] + [[IVLPlaybackManager shared] songOffsetMs]; }

#pragma mark - Outgoing (main thread snapshot -> socket queue)

static NSString *IVLWNPField(NSString *s) {
    if (!s.length) return @"\x01";
    return [s stringByReplacingOccurrencesOfString:@"|" withString:@"\\|"];
}

static NSString *IVLWNPTime(double seconds) {
    long s = (long)MAX(0, llround(seconds));
    return s >= 3600 ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", s / 3600, (s / 60) % 60, s % 60]
                     : [NSString stringWithFormat:@"%ld:%02ld", s / 60, s % 60];
}

- (void)push {
    if (![IVLSettings boolForKey:IVLKeyWNPEnabled]) return;
    IVLPlaybackManager *m = [IVLPlaybackManager shared];
    IVLTrack *t = m.track;
    NSDictionary *np = [IVLLockScreen shared].originalInfo ?: [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo;
    NSString *title = t.title ?: [np[MPMediaItemPropertyTitle] description] ?: @"";
    NSString *artist = t.artist ?: [np[MPMediaItemPropertyArtist] description] ?: @"";
    NSString *album = [np[MPMediaItemPropertyAlbumTitle] isKindOfClass:[NSString class]] ? np[MPMediaItemPropertyAlbumTitle] : @"";
    double duration = t.duration > 0 ? t.duration : [np[MPMediaItemPropertyPlaybackDuration] doubleValue];
    double position = [m rawTimeMs] / 1000.0;
    BOOL playing = [IVLRemoteControl isPlaying];
    int state = title.length ? (playing ? WNP_PLAYING : WNP_PAUSED) : WNP_STOPPED;
    NSString *cover = @"";
    if (t.youtubeVideoID.length == 11) cover = [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg", t.youtubeVideoID];
    else if (t.artworkURL.length) cover = t.artworkURL;
    NSData *coverPNG = nil;
    NSString *coverKey = t.videoID ?: title;
    if ([t.artworkImage isKindOfClass:[UIImage class]] && ![coverKey isEqualToString:_lastCoverKey]) {
        coverPNG = UIImagePNGRepresentation((UIImage *)t.artworkImage);
    }
    long long now = (long long)(NSDate.date.timeIntervalSince1970 * 1000);

    dispatch_async(_q, ^{
        if (!self->_conn || !self->_revision) return;
        NSString *rev = self->_revision;
        if ([rev isEqualToString:@"3"]) {
            if (coverPNG && ![coverKey isEqualToString:self->_lastCoverKey]) {
                // binary frame: uint32 little-endian player id + PNG
                NSMutableData *d = [NSMutableData dataWithCapacity:coverPNG.length + 4];
                uint32_t pid = CFSwapInt32HostToLittle(kPlayerID);
                [d appendBytes:&pid length:4];
                [d appendData:coverPNG];
                [self sendData:d opcode:nw_ws_opcode_binary];
                self->_lastCoverKey = coverKey;
            }
            NSArray *fields = @[
                @(kPlayerID).stringValue, IVLWNPField(@"YouTube Music"), IVLWNPField(title), IVLWNPField(artist), IVLWNPField(album),
                IVLWNPField(cover), @(state).stringValue, @((long)llround(position)).stringValue, @((long)llround(duration)).stringValue,
                @"100", @"0", @"1", @"0",                                    // volume, rating, repeat NONE, shuffle off
                @"0", @"1",                                                  // rating system NONE, available repeat NONE
                @"1", @"1", @"1", @"1", @"0", @"0", @"0", @"0",              // can: state, prev, next, position, volume, rating, repeat, shuffle
                @(self->_createdAt).stringValue, @(now).stringValue, @(playing ? now : self->_createdAt).stringValue,
            ];
            NSString *data = [[fields componentsJoinedByString:@"|"] stringByAppendingString:@"|"];
            // only resend when something besides the clock changed, or every 5 s to keep position fresh
            NSString *key = [NSString stringWithFormat:@"%@|%d|%@", title, state, @((long)llround(position) / 5)];
            if ([key isEqualToString:self->_cache[@"rev3"]] && self->_playerAdded) return;
            self->_cache[@"rev3"] = key;
            [self sendText:[NSString stringWithFormat:@"%d %d %@", self->_playerAdded ? WNP_PLAYER_UPDATED : WNP_PLAYER_ADDED, kPlayerID, data]];
            self->_playerAdded = YES;
            return;
        }
        BOOL legacy = [rev isEqualToString:@"legacy"];
        BOOL rev2 = [rev isEqualToString:@"2"];
        NSString *sep = legacy ? @":" : @" ";
        NSString *stateText = legacy ? @(state == WNP_PLAYING ? 1 : state == WNP_PAUSED ? 2 : 0).stringValue
                                     : (state == WNP_PLAYING ? @"PLAYING" : state == WNP_PAUSED ? @"PAUSED" : @"STOPPED");
        NSArray *pairs = @[
            @[rev2 ? @"PLAYER_NAME" : @"PLAYER", @"YouTube Music"], @[@"TITLE", title], @[@"ARTIST", artist], @[@"ALBUM", album],
            @[rev2 ? @"COVER_URL" : @"COVER", cover], @[@"STATE", stateText],
            @[rev2 ? @"DURATION_SECONDS" : @"DURATION", rev2 ? @((long)llround(duration)).stringValue : IVLWNPTime(duration)],
            @[rev2 ? @"POSITION_SECONDS" : @"POSITION", rev2 ? @((long)llround(position)).stringValue : IVLWNPTime(position)],
            @[@"VOLUME", @"100"],
        ];
        for (NSArray *kv in pairs) {
            if ([self->_cache[kv[0]] isEqual:kv[1]]) continue;
            self->_cache[kv[0]] = kv[1];
            [self sendText:[NSString stringWithFormat:@"%@%@%@", kv[0], sep, kv[1]]];
        }
    });
}

@end
