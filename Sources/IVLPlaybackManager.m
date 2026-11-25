#import "IVLPlaybackManager.h"
#import "IVLLyricsService.h"
#import "IVLTranslator.h"
#import "IVLSettings.h"
#import "YTMHeaders.h"
#import <QuartzCore/QuartzCore.h>
#import <MediaPlayer/MediaPlayer.h>
#import "IVLLockScreen.h"
#import <CommonCrypto/CommonDigest.h>

NSNotificationName const IVLTrackDidChangeNotification = @"IVLTrackDidChangeNotification";
NSNotificationName const IVLLyricsDidChangeNotification = @"IVLLyricsDidChangeNotification";

@interface IVLPlaybackManager ()
@property (nonatomic, strong, readwrite) IVLTrack *track;
@property (nonatomic, strong, readwrite) IVLLyrics *lyrics;
@property (nonatomic, assign, readwrite) IVLLyricsState state;
@property (nonatomic, assign, readwrite) BOOL translating;
@end

@implementation IVLPlaybackManager {
    NSUInteger _generation;
    NSInteger _lastRaw;
    CFTimeInterval _lastRawChange;
    BOOL _playing;
    NSString *_lastPlayerVid;
    NSDictionary *_npInfo;
    CFTimeInterval _npStamp;
    NSString *_npKey;
    NSUInteger _activateCount, _heartbeatCount, _npCount;
}

+ (instancetype)shared {
    static IVLPlaybackManager *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [self new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(settingsChanged:) name:IVLSettingsDidChangeNotification object:nil];
    }
    return self;
}

- (void)settingsChanged:(NSNotification *)n {
    NSString *key = n.object;
    if ([key isEqualToString:IVLKeyEnabled]) {
        if ([IVLSettings boolForKey:IVLKeyEnabled] && !self.track) [self scheduleResolve];
        return;
    }
    if ([key isEqualToString:IVLKeyTranslation] || [key isEqualToString:IVLKeyTranslationLang] || [key isEqualToString:IVLKeyPronunciation]) {
        [self refreshExtras];
    } else if ([key isEqualToString:IVLKeyProviderUnison] || [key isEqualToString:IVLKeyProviderLRCLIB] || [key isEqualToString:IVLKeyProviderOrder]
               || [key isEqualToString:IVLKeyProviderLyricsPlus] || [key isEqualToString:IVLKeyProviderYouTube]
               || [key isEqualToString:IVLKeyProviderSpotify] || [key isEqualToString:IVLKeyProviderCaptions] || [key isEqualToString:IVLKeyProviderLyrically]) {
        if (self.state == IVLLyricsStateNotFound || self.state == IVLLyricsStateError) [self reloadLyrics];
    }
}

#pragma mark - Track detection
// Two independent sources:
//  1. YTPlayerViewController (videoID, exact position, seek) - private, may change between app versions
//  2. MPNowPlayingInfoCenter (title, artist, duration, artwork, elapsed) - public API, always available

static NSString *IVLStr(id v) { return [v isKindOfClass:[NSString class]] ? v : nil; }

static BOOL IVLLooseEqual(NSString *a, NSString *b) {
    if (!a.length || !b.length) return NO;
    NSString *x = a.lowercaseString, *y = b.lowercaseString;
    return [x isEqualToString:y] || [x containsString:y] || [y containsString:x];
}

static NSString *IVLSyntheticKey(NSString *title, NSString *artist) {
    NSData *d = [[NSString stringWithFormat:@"%@\n%@", title ?: @"", artist ?: @""] dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char out[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(d.bytes, (CC_LONG)d.length, out);
    NSMutableString *h = [NSMutableString stringWithString:@"np_"];
    for (int i = 0; i < 10; i++) [h appendFormat:@"%02x", out[i]];
    return h;
}

- (void)scheduleResolve {
    if (![IVLSettings boolForKey:IVLKeyEnabled]) return;
    NSUInteger gen = ++_generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self resolveTrackAttempt:0 generation:gen];
    });
}

- (void)playerDidActivateVideo:(UIViewController *)player {
    _activateCount++;
    if (player) self.player = player;
    _lastPlayerVid = [self playerVideoID];
    [self scheduleResolve];
}

- (void)playerHeartbeat:(UIViewController *)player {
    _heartbeatCount++;
    if (!self.player) self.player = player;
    if (player != self.player || ![IVLSettings boolForKey:IVLKeyEnabled]) return;
    NSString *vid = [self playerVideoID];
    if (!vid.length || [vid isEqualToString:_lastPlayerVid]) return;
    _lastPlayerVid = vid;
    [self scheduleResolve];
}

- (void)nowPlayingInfoDidChange:(NSDictionary *)info {
    NSDictionary *copy = [info isKindOfClass:[NSDictionary class]] ? [info copy] : nil;
    CFTimeInterval stamp = CACurrentMediaTime();
    void (^apply)(void) = ^{
        self->_npCount++;
        if (!copy) return;
        self->_npInfo = copy;
        self->_npStamp = stamp;
        NSString *title = IVLStr(copy[MPMediaItemPropertyTitle]);
        NSString *key = [NSString stringWithFormat:@"%@\n%@", title ?: @"", IVLStr(copy[MPMediaItemPropertyArtist]) ?: @""];
        if (title.length && ![key isEqualToString:self->_npKey]) {
            self->_npKey = key;
            [self scheduleResolve];
        }
    };
    if (NSThread.isMainThread) apply(); else dispatch_async(dispatch_get_main_queue(), apply);
}

- (void)refreshNow {
    if (!_npInfo) {
        NSDictionary *info = ([IVLLockScreen shared].originalInfo ?: [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo);
        if (info.count) [self nowPlayingInfoDidChange:info];
    }
    if (!self.track) [self scheduleResolve];
}

- (NSString *)diagnostics {
    NSDictionary *np = _npInfo ?: ([IVLLockScreen shared].originalInfo ?: [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo);
    return [NSString stringWithFormat:@"player %@ · nowPlaying %@ · act %lu · hb %lu · np %lu",
            self.player ? @"✓" : @"✗", IVLStr(np[MPMediaItemPropertyTitle]).length ? @"✓" : @"✗",
            (unsigned long)_activateCount, (unsigned long)_heartbeatCount, (unsigned long)_npCount];
}

- (NSString *)playerVideoID {
    YTPlayerViewController *p = (YTPlayerViewController *)self.player;
    NSString *vid = nil;
    @try {
        if ([p respondsToSelector:@selector(currentVideoID)]) vid = IVLStr([p currentVideoID]);
        if (!vid.length && [p respondsToSelector:@selector(contentVideoID)]) vid = IVLStr(p.contentVideoID);
    } @catch (__unused NSException *e) {}
    return vid;
}

- (void)resolveTrackAttempt:(NSInteger)attempt generation:(NSUInteger)gen {
    if (gen != _generation) return;
    void (^retry)(void) = ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self resolveTrackAttempt:attempt + 1 generation:gen];
        });
    };

    // --- player side
    YTPlayerViewController *p = (YTPlayerViewController *)self.player;
    NSString *pVid = [self playerVideoID];
    YTIVideoDetails *details = nil;
    NSString *pTitle = nil, *pArtist = nil, *pThumb = nil;
    CGFloat pDuration = 0;
    @try {
        if ([p respondsToSelector:@selector(playerResponse)]) {
            YTPlayerResponse *resp = p.playerResponse;
            if ([resp respondsToSelector:@selector(playerData)]) {
                YTIPlayerResponse *data = resp.playerData;
                if ([data respondsToSelector:@selector(videoDetails)]) details = data.videoDetails;
            }
        }
        if ([details respondsToSelector:@selector(title)]) pTitle = IVLStr(details.title);
        if ([details respondsToSelector:@selector(author)]) pArtist = IVLStr(details.author);
        if ([details respondsToSelector:@selector(videoId)]) {
            NSString *dv = IVLStr(details.videoId);
            if (!pVid.length) pVid = dv;
            else if (dv.length && ![dv isEqualToString:pVid]) pTitle = nil;   // response still from the previous song
        }
        if ([p respondsToSelector:@selector(currentVideoTotalMediaTime)]) pDuration = p.currentVideoTotalMediaTime;
        if ([details respondsToSelector:@selector(thumbnail)]) {
            YTIThumbnailDetails_Thumbnail *thumb = [details.thumbnail.thumbnailsArray lastObject];
            if ([thumb respondsToSelector:@selector(URL)]) pThumb = IVLStr(thumb.URL);
        }
    } @catch (__unused NSException *e) {}

    // --- system now playing side
    NSDictionary *np = _npInfo ?: ([IVLLockScreen shared].originalInfo ?: [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo);
    NSString *nTitle = IVLStr(np[MPMediaItemPropertyTitle]);
    NSString *nArtist = IVLStr(np[MPMediaItemPropertyArtist]);
    double nDuration = [np[MPMediaItemPropertyPlaybackDuration] doubleValue];

    NSString *title, *artist, *vid = nil;
    double duration;
    if (nTitle.length) {
        title = nTitle;
        artist = nArtist.length ? nArtist : (pArtist ?: @"");
        duration = nDuration > 0 ? nDuration : pDuration;
        if (pVid.length && IVLLooseEqual(pTitle, nTitle)) vid = pVid;
        else if (p && attempt < 6) { retry(); return; }   // give the player a moment to catch up
    } else if (pVid.length && pTitle.length) {
        if (pDuration <= 0 && attempt < 8) { retry(); return; }
        title = pTitle; artist = pArtist ?: @""; duration = pDuration; vid = pVid;
    } else {
        if (attempt < 20) retry();
        return;
    }

    NSString *key = vid.length ? vid : IVLSyntheticKey(title, artist);
    if ([self.track.videoID isEqualToString:key]) return;

    IVLTrack *t = [IVLTrack new];
    t.videoID = key;
    t.youtubeVideoID = vid.length ? vid : nil;
    t.title = title;
    t.artist = artist;
    t.duration = duration;
    id art = np[MPMediaItemPropertyArtwork];
    if (nTitle.length && [art isKindOfClass:[MPMediaItemArtwork class]] && ![[IVLLockScreen shared] isRenderedArtwork:art]) {
        @try { t.artworkImage = [(MPMediaItemArtwork *)art imageWithSize:CGSizeMake(600, 600)]; } @catch (__unused NSException *e) {}
    }
    if (vid && pThumb.length) {
        // request a larger square artwork from googleusercontent ("w120-h120")
        t.artworkURL = [pThumb stringByReplacingOccurrencesOfString:@"w\\d+-h\\d+" withString:@"w720-h720" options:NSRegularExpressionSearch range:NSMakeRange(0, pThumb.length)];
    }

    self.track = t;
    self.lyrics = nil;
    [[NSNotificationCenter defaultCenter] postNotificationName:IVLTrackDidChangeNotification object:self];
    [self loadLyricsIgnoringCache:NO];
}

#pragma mark - Lyrics

- (void)loadLyricsIgnoringCache:(BOOL)ignoreCache {
    IVLTrack *t = self.track;
    if (!t) return;
    if (ignoreCache) [[IVLLyricsService shared] removeCachedLyricsForVideoID:t.videoID];
    self.state = IVLLyricsStateLoading;
    self.lyrics = nil;
    [[NSNotificationCenter defaultCenter] postNotificationName:IVLLyricsDidChangeNotification object:self];

    NSString *vid = t.videoID;
    [[IVLLyricsService shared] lyricsForTrack:t completion:^(IVLLyrics *ly, NSError *err) {
        if (![self.track.videoID isEqualToString:vid]) return;
        self.lyrics = ly;
        self.state = ly ? IVLLyricsStateLoaded : (err ? IVLLyricsStateError : IVLLyricsStateNotFound);
        [self refreshExtras];
    }];
}

- (void)reloadLyrics { [self loadLyricsIgnoringCache:YES]; }

- (void)useManualLyrics:(IVLLyrics *)lyrics {
    if (!self.track || !lyrics) return;
    [[IVLLyricsService shared] saveManualLyrics:lyrics forVideoID:self.track.videoID];
    self.lyrics = lyrics;
    self.state = IVLLyricsStateLoaded;
    [self refreshExtras];
}

- (void)refreshExtras {
    IVLLyrics *ly = self.lyrics;
    if (ly) {
        [IVLPronunciation applyToLyrics:ly mode:[IVLSettings integerForKey:IVLKeyPronunciation]];
        if (![IVLSettings boolForKey:IVLKeyTranslation]) {
            for (IVLLyricLine *l in ly.lines) l.translation = nil;
        }
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:IVLLyricsDidChangeNotification object:self];

    if (ly && [IVLSettings boolForKey:IVLKeyTranslation]) {
        NSString *lang = [IVLSettings objectForKey:IVLKeyTranslationLang];
        self.translating = YES;
        [[IVLTranslator shared] translateLyrics:ly videoID:self.track.videoID target:lang completion:^(BOOL ok) {
            self.translating = NO;
            if (ly == self.lyrics) [[NSNotificationCenter defaultCenter] postNotificationName:IVLLyricsDidChangeNotification object:self];
        }];
    }
}

#pragma mark - Time

- (NSInteger)rawTimeMs {
    YTPlayerViewController *p = (YTPlayerViewController *)self.player;
    if (![p respondsToSelector:@selector(currentVideoMediaTime)]) {
        // system now-playing fallback: elapsed + (now - when it was set) * rate
        if (!_npInfo) return 0;
        double elapsed = [_npInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue];
        id rateObj = _npInfo[MPNowPlayingInfoPropertyPlaybackRate];
        double rate = rateObj ? [rateObj doubleValue] : 1.0;
        _playing = rate > 0;
        return (NSInteger)llround((elapsed + (CACurrentMediaTime() - _npStamp) * rate) * 1000.0);
    }
    NSInteger raw = (NSInteger)llround([p currentVideoMediaTime] * 1000.0);
    CFTimeInterval now = CACurrentMediaTime();
    if (raw != _lastRaw) {
        NSInteger diff = raw - _lastRaw;
        _playing = diff > 0 && diff < 1500;
        _lastRaw = raw;
        _lastRawChange = now;
        return raw;
    }
    // The player reports at a coarse interval: extrapolate between updates for smooth karaoke.
    CFTimeInterval since = now - _lastRawChange;
    if (since > 1.0) _playing = NO;
    if (_playing) return raw + (NSInteger)(MIN(since, 0.5) * 1000.0);
    return raw;
}

- (BOOL)isPlaying { return _playing; }

- (NSInteger)songOffsetMs { return [IVLSettings songOffsetForVideoID:self.track.videoID]; }
- (void)setSongOffsetMs:(NSInteger)ms { [IVLSettings setSongOffset:ms forVideoID:self.track.videoID]; }

- (NSInteger)currentTimeMs {
    return [self rawTimeMs] + [IVLSettings integerForKey:IVLKeyGlobalOffset] + [self songOffsetMs];
}

- (void)seekToMs:(NSInteger)ms {
    YTPlayerViewController *p = (YTPlayerViewController *)self.player;
    if (![p respondsToSelector:@selector(seekToTime:)]) return;
    NSInteger raw = MAX(0, ms - [IVLSettings integerForKey:IVLKeyGlobalOffset] - [self songOffsetMs]);
    [p seekToTime:raw / 1000.0];
    _lastRaw = raw;
    _lastRawChange = CACurrentMediaTime();
}

- (NSString *)currentLineText {
    IVLLyrics *ly = self.lyrics;
    if (!ly.synced || !ly.lines.count) return nil;
    NSInteger idx = [ly indexOfLineAtTime:[self currentTimeMs]];
    if (idx < 0) return nil;
    IVLLyricLine *l = ly.lines[idx];
    return l.instrumental ? @"♪" : l.text;
}

@end
