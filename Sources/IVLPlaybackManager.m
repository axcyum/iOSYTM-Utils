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
    NSString *_committedPlayerVid;
    NSString *_committedNPKey;
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
        if ([IVLSettings boolForKey:IVLKeyEnabled] && !self.track) [self resolveImmediately];
        return;
    }
    if ([key isEqualToString:IVLKeyTranslation] || [key isEqualToString:IVLKeyTranslationLang] || [key isEqualToString:IVLKeyPronunciation]) {
        [self refreshExtras];
    } else if ([key isEqualToString:IVLKeyProviderUnison] || [key isEqualToString:IVLKeyProviderLRCLIB] || [key isEqualToString:IVLKeyProviderOrder]
               || [key isEqualToString:IVLKeyProviderLyricsPlus] || [key isEqualToString:IVLKeyProviderYouTube]
               || [key isEqualToString:IVLKeyProviderSpotify] || [key isEqualToString:IVLKeyProviderCaptions]
               || [key isEqualToString:IVLKeyCaptionLang] || [key isEqualToString:IVLKeyProviderLyrically]) {
        if (self.state == IVLLyricsStateNotFound || self.state == IVLLyricsStateError) [self reloadLyrics];
    }
}

#pragma mark - Track detection

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

- (void)resolveImmediately {
    if (![IVLSettings boolForKey:IVLKeyEnabled]) return;
    void (^run)(void) = ^{
        NSUInteger gen = ++self->_generation;
        [self resolveTrackAttempt:0 generation:gen];
    };
    if (NSThread.isMainThread) run();
    else dispatch_async(dispatch_get_main_queue(), run);
}

- (void)playerDidActivateVideo:(UIViewController *)player {
    _activateCount++;
    if (player) self.player = player;
    _lastPlayerVid = [self playerVideoID];
    [self resolveImmediately];
}

- (void)playerHeartbeat:(UIViewController *)player {
    _heartbeatCount++;
    if (!self.player) self.player = player;
    if (player != self.player || ![IVLSettings boolForKey:IVLKeyEnabled]) return;
    NSString *vid = [self playerVideoID];
    if (!vid.length || [vid isEqualToString:_lastPlayerVid]) return;
    _lastPlayerVid = vid;
    [self resolveImmediately];
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
        NSString *artist = IVLStr(copy[MPMediaItemPropertyArtist]) ?: @"";
        NSString *key = [NSString stringWithFormat:@"%@\n%@", title ?: @"", artist];
        if (!title.length) return;

        // If the track was already resolved instantly from YTPlayerViewController, fill in any missing
        // MPMediaItemArtwork when system NowPlaying catches up without restarting lyric loading.
        if (self.track && ![key isEqualToString:self->_committedNPKey ?: @""] && IVLLooseEqual(self.track.title, title)) {
            self->_npKey = key;
            self->_committedNPKey = key;
            if (!self.track.artworkImage) {
                id art = copy[MPMediaItemPropertyArtwork];
                if ([art isKindOfClass:[MPMediaItemArtwork class]] && ![[IVLLockScreen shared] isRenderedArtwork:art]) {
                    @try { self.track.artworkImage = [(MPMediaItemArtwork *)art imageWithSize:CGSizeMake(600, 600)]; } @catch (__unused NSException *e) {}
                    if (self.track.artworkImage) {
                        [[NSNotificationCenter defaultCenter] postNotificationName:IVLTrackDidChangeNotification object:self];
                    }
                }
            }
            if (self.track.duration <= 0) {
                double nDur = [copy[MPMediaItemPropertyPlaybackDuration] doubleValue];
                if (nDur > 0) self.track.duration = nDur;
            }
            return;
        }

        if (![key isEqualToString:self->_npKey]) {
            self->_npKey = key;
            [self resolveImmediately];
        }
    };
    if (NSThread.isMainThread) apply(); else dispatch_async(dispatch_get_main_queue(), apply);
}

- (void)refreshNow {
    if (!_npInfo) {
        NSDictionary *info = ([IVLLockScreen shared].originalInfo ?: [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo);
        if (info.count) [self nowPlayingInfoDidChange:info];
    }
    if (!self.track) [self resolveImmediately];
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

- (void)readPlayerTitle:(NSString **)outTitle artist:(NSString **)outArtist vid:(NSString **)outVid thumb:(NSString **)outThumb duration:(CGFloat *)outDur {
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
            else if (dv.length && ![dv isEqualToString:pVid]) {
                // playerResponse still belongs to the previous video; ignore its stale metadata
                pTitle = nil; pArtist = nil; pThumb = nil;
            }
        }
        if ([p respondsToSelector:@selector(currentVideoTotalMediaTime)]) pDuration = p.currentVideoTotalMediaTime;
        if (pTitle.length && [details respondsToSelector:@selector(thumbnail)]) {
            YTIThumbnailDetails_Thumbnail *thumb = [details.thumbnail.thumbnailsArray lastObject];
            if ([thumb respondsToSelector:@selector(URL)]) pThumb = IVLStr(thumb.URL);
        }
    } @catch (__unused NSException *e) {}
    if (outTitle) *outTitle = pTitle;
    if (outArtist) *outArtist = pArtist;
    if (outVid) *outVid = pVid;
    if (outThumb) *outThumb = pThumb;
    if (outDur) *outDur = pDuration;
}

/// If we committed immediately from NowPlaying before YTPlayerViewController flipped its videoID,
/// upgrade the track in-place once the player catches up (within ~1s).
- (void)upgradeVideoIDForTrack:(IVLTrack *)target attempt:(NSInteger)attempt {
    if (self.track != target || target.youtubeVideoID.length == 11 || attempt >= 12) return;
    NSString *pTitle = nil, *pArtist = nil, *pVid = nil, *pThumb = nil;
    CGFloat pDuration = 0;
    [self readPlayerTitle:&pTitle artist:&pArtist vid:&pVid thumb:&pThumb duration:&pDuration];
    BOOL sameLen = pDuration > 0 && target.duration > 0 && fabs(pDuration - target.duration) < 2.0;
    if (pVid.length && (IVLLooseEqual(pTitle, target.title) || (pTitle.length && sameLen))) {
        _committedPlayerVid = pVid;
        target.videoID = pVid;
        target.youtubeVideoID = pVid;
        if (pThumb.length) {
            target.artworkURL = [pThumb stringByReplacingOccurrencesOfString:@"w\\d+-h\\d+" withString:@"w720-h720" options:NSRegularExpressionSearch range:NSMakeRange(0, pThumb.length)];
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:IVLTrackDidChangeNotification object:self];
        if (self.state == IVLLyricsStateNotFound || self.state == IVLLyricsStateError) [self loadLyricsIgnoringCache:NO];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self upgradeVideoIDForTrack:target attempt:attempt + 1];
    });
}

- (void)resolveTrackAttempt:(NSInteger)attempt generation:(NSUInteger)gen {
    if (gen != _generation) return;
    void (^retryFast)(void) = ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self resolveTrackAttempt:attempt + 1 generation:gen];
        });
    };

    NSString *pTitle = nil, *pArtist = nil, *pVid = nil, *pThumb = nil;
    CGFloat pDuration = 0;
    [self readPlayerTitle:&pTitle artist:&pArtist vid:&pVid thumb:&pThumb duration:&pDuration];

    NSDictionary *np = _npInfo ?: ([IVLLockScreen shared].originalInfo ?: [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo);
    NSString *nTitle = IVLStr(np[MPMediaItemPropertyTitle]);
    NSString *nArtist = IVLStr(np[MPMediaItemPropertyArtist]);
    double nDuration = [np[MPMediaItemPropertyPlaybackDuration] doubleValue];
    NSString *npKey = nTitle.length ? [NSString stringWithFormat:@"%@\n%@", nTitle, nArtist ?: @""] : nil;

    BOOL pIsNew = pVid.length > 0 && ![pVid isEqualToString:_committedPlayerVid ?: @""];
    BOOL npIsNew = npKey.length > 0 && ![npKey isEqualToString:_committedNPKey ?: @""];
    BOOL sameLength = pDuration > 0 && nDuration > 0 && fabs(pDuration - nDuration) < 2.0;
    BOOL bothMatch = pVid.length && nTitle.length && (IVLLooseEqual(pTitle, nTitle) || (pTitle.length && sameLength));

    NSString *title = nil, *artist = nil, *vid = nil;
    double duration = 0;
    BOOL useNPArt = NO;

    if (bothMatch) {
        title = nTitle;
        artist = nArtist.length ? nArtist : (pArtist ?: @"");
        duration = nDuration > 0 ? nDuration : pDuration;
        vid = pVid;
        useNPArt = YES;
        _committedPlayerVid = pVid;
        _committedNPKey = npKey;
    } else if (pIsNew && !npIsNew) {
        // Player switched to a new track while MPNowPlayingInfoCenter still holds the old song!
        // Never wait for stale NowPlaying — switch immediately as soon as playerDetails is ready.
        if (pTitle.length) {
            title = pTitle;
            artist = pArtist ?: @"";
            duration = pDuration > 0 ? pDuration : 0;
            vid = pVid;
            useNPArt = NO;
            _committedPlayerVid = pVid;
        } else if (attempt < 16) {
            retryFast();
            return;
        } else {
            return;
        }
    } else if (npIsNew) {
        // System NowPlaying switched first; give YTPlayerViewController 1 fast 50ms tick to flip its videoID,
        // then commit immediately so the UI never lags behind on skip.
        if (self.player && attempt < 1) {
            retryFast();
            return;
        }
        title = nTitle;
        artist = nArtist ?: @"";
        duration = nDuration > 0 ? nDuration : pDuration;
        vid = nil;
        useNPArt = YES;
        _committedNPKey = npKey;
    } else if (nTitle.length) {
        title = nTitle;
        artist = nArtist.length ? nArtist : (pArtist ?: @"");
        duration = nDuration > 0 ? nDuration : pDuration;
        vid = bothMatch ? pVid : nil;
        useNPArt = YES;
        _committedNPKey = npKey;
        if (vid.length) _committedPlayerVid = vid;
    } else if (pVid.length && pTitle.length) {
        title = pTitle;
        artist = pArtist ?: @"";
        duration = pDuration;
        vid = pVid;
        _committedPlayerVid = pVid;
    } else {
        if (attempt < 25) retryFast();
        return;
    }

    NSString *key = vid.length ? vid : IVLSyntheticKey(title, artist);
    if ([self.track.videoID isEqualToString:key] || (vid.length && [self.track.youtubeVideoID isEqualToString:vid])) {
        if (useNPArt && !self.track.artworkImage) {
            id art = np[MPMediaItemPropertyArtwork];
            if ([art isKindOfClass:[MPMediaItemArtwork class]] && ![[IVLLockScreen shared] isRenderedArtwork:art]) {
                @try { self.track.artworkImage = [(MPMediaItemArtwork *)art imageWithSize:CGSizeMake(600, 600)]; } @catch (__unused NSException *e) {}
                if (self.track.artworkImage) [[NSNotificationCenter defaultCenter] postNotificationName:IVLTrackDidChangeNotification object:self];
            }
        }
        return;
    }

    IVLTrack *t = [IVLTrack new];
    t.videoID = key;
    t.youtubeVideoID = vid.length ? vid : nil;
    t.title = title;
    t.artist = artist;
    t.duration = duration;
    if (useNPArt) {
        id art = np[MPMediaItemPropertyArtwork];
        if ([art isKindOfClass:[MPMediaItemArtwork class]] && ![[IVLLockScreen shared] isRenderedArtwork:art]) {
            @try { t.artworkImage = [(MPMediaItemArtwork *)art imageWithSize:CGSizeMake(600, 600)]; } @catch (__unused NSException *e) {}
        }
    }
    if (vid.length && pThumb.length) {
        t.artworkURL = [pThumb stringByReplacingOccurrencesOfString:@"w\\d+-h\\d+" withString:@"w720-h720" options:NSRegularExpressionSearch range:NSMakeRange(0, pThumb.length)];
    }

    _lastRaw = 0;
    _lastRawChange = CACurrentMediaTime();
    self.track = t;
    self.lyrics = nil;
    [[NSNotificationCenter defaultCenter] postNotificationName:IVLTrackDidChangeNotification object:self];
    [self loadLyricsIgnoringCache:NO];

    if (!vid.length && self.player) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self upgradeVideoIDForTrack:t attempt:0];
        });
    }
}

#pragma mark - Lyrics

- (void)loadLyricsIgnoringCache:(BOOL)ignoreCache {
    IVLTrack *t = self.track;
    if (!t) return;
    if (ignoreCache) [[IVLLyricsService shared] removeCachedLyricsForVideoID:t.videoID];
    self.state = IVLLyricsStateLoading;
    self.lyrics = nil;
    [[NSNotificationCenter defaultCenter] postNotificationName:IVLLyricsDidChangeNotification object:self];

    __weak IVLTrack *weakTrack = t;
    [[IVLLyricsService shared] lyricsForTrack:t completion:^(IVLLyrics *ly, NSError *err) {
        if (self.track != weakTrack) return;
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
