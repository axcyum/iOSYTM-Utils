#import "IVLPlaybackManager.h"
#import "IVLLyricsService.h"
#import "IVLLyricsService+Private.h"
#import "IVLTranslator.h"
#import "IVLSettings.h"
#import "YTMHeaders.h"
#import <QuartzCore/QuartzCore.h>
#import <MediaPlayer/MediaPlayer.h>
#import "IVLLockScreen.h"
#import <CommonCrypto/CommonDigest.h>

NSNotificationName const IVLTrackDidChangeNotification = @"IVLTrackDidChangeNotification";
NSNotificationName const IVLArtworkDidChangeNotification = @"IVLArtworkDidChangeNotification";
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
    NSString *_staleNPKey;
    NSDictionary *_npInfo;
    CFTimeInterval _npStamp;
    NSString *_npKey;
    BOOL _artworkIsFallback;
    BOOL _artworkURLInFlight;
    BOOL _vidSearchInFlight;
    NSCache<NSString *, UIImage *> *_artCache;
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
        _artCache = [NSCache new];
        _artCache.countLimit = 30;
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

#pragma mark - Helpers & Artwork Extraction

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

/// Safely extracts UIImage from an MPMediaItemArtwork (skipping LockLyrics' rendered frames),
/// trying multiple target sizes in case the app's requestHandler expects native bounds.
static UIImage *IVLExtractNPArtwork(id artObj) {
    if (![artObj isKindOfClass:[MPMediaItemArtwork class]]) return nil;
    if ([[IVLLockScreen shared] isRenderedArtwork:artObj]) return nil;
    MPMediaItemArtwork *art = (MPMediaItemArtwork *)artObj;
    UIImage *img = nil;
    @try { img = [art imageWithSize:CGSizeMake(720, 720)]; } @catch (__unused NSException *e) {}
    if ((!img || img.size.width <= 1) && art.bounds.size.width > 1 && art.bounds.size.height > 1) {
        @try { img = [art imageWithSize:art.bounds.size]; } @catch (__unused NSException *e) {}
    }
    if (!img || img.size.width <= 1) {
        @try { img = [art imageWithSize:CGSizeMake(320, 320)]; } @catch (__unused NSException *e) {}
    }
    return (img && img.size.width > 1 && img.size.height > 1) ? img : nil;
}

/// Builds an ordered list of candidate URLs for a thumbnail without breaking signed googleusercontent URLs.
static NSArray<NSString *> *IVLCandidateThumbURLs(NSString *rawThumb, NSString *vid) {
    NSMutableArray<NSString *> *urls = [NSMutableArray array];
    if (rawThumb.length) {
        NSURLComponents *comp = [NSURLComponents componentsWithString:rawThumb];
        NSString *host = comp.host.lowercaseString ?: @"";
        if ([comp.scheme isEqualToString:@"https"] && ([host hasSuffix:@"googleusercontent.com"] || [host hasSuffix:@"ggpht.com"])) {
            NSString *path = comp.percentEncodedPath ?: @"";
            NSRange eq = [path rangeOfString:@"=" options:NSBackwardsSearch];
            if (eq.location != NSNotFound) {
                NSString *basePath = [path substringToIndex:eq.location];
                NSString *clean720 = [NSString stringWithFormat:@"https://%@%@=w720-h720-l90-rj", comp.host, basePath];
                [urls addObject:clean720];
            }
        }
        if (![urls containsObject:rawThumb]) [urls addObject:rawThumb];
    }
    if (vid.length == 11) {
        [urls addObject:[NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg", vid]];
    }
    return urls;
}

- (void)applyArtwork:(UIImage *)img isFallback:(BOOL)isFallback forTrack:(IVLTrack *)target {
    if (!img || self.track != target) return;
    if (target.artworkImage && !_artworkIsFallback && isFallback) return;
    BOOL changed = (target.artworkImage != img);
    target.artworkImage = img;
    _artworkIsFallback = isFallback;
    if (changed) {
        [[NSNotificationCenter defaultCenter] postNotificationName:IVLArtworkDidChangeNotification object:self];
    }
}

/// Checks IVLLockScreen.originalInfo, _npInfo, and MPNowPlayingInfoCenter.defaultCenter for matching MPMediaItemArtwork.
- (UIImage *)probeSystemArtworkForTrack:(IVLTrack *)target {
    if (!target) return nil;
    NSArray *sources = @[
        [IVLLockScreen shared].originalInfo ?: @{},
        _npInfo ?: @{},
        [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo ?: @{},
    ];
    for (NSDictionary *info in sources) {
        if (!info.count) continue;
        NSString *nTitle = IVLStr(info[MPMediaItemPropertyTitle]);
        NSString *nArtist = IVLStr(info[MPMediaItemPropertyArtist]) ?: @"";
        NSString *infoKey = nTitle.length ? [NSString stringWithFormat:@"%@\n%@", nTitle, nArtist] : @"";
        double nDur = [info[MPMediaItemPropertyPlaybackDuration] doubleValue];
        BOOL sameDur = (nDur > 0 && target.duration > 0 && fabs(nDur - target.duration) < 2.5);
        BOOL notStale = infoKey.length > 0 && ![infoKey isEqualToString:_staleNPKey ?: @""];
        // Accept NP artwork if title matches OR if NowPlaying has already moved off the previous song
        // (handles tracks whose YouTube videoDetails title is English while YTM NowPlaying title is Japanese).
        if (nTitle.length && !IVLLooseEqual(target.title, nTitle) && !(notStale && (sameDur || !target.duration))) {
            continue;
        }
        UIImage *img = IVLExtractNPArtwork(info[MPMediaItemPropertyArtwork]);
        if (img) return img;
    }
    return nil;
}

- (void)downloadThumbCandidates:(NSArray<NSString *> *)urls index:(NSUInteger)idx forTrack:(IVLTrack *)target {
    if (self.track != target || idx >= urls.count) {
        _artworkURLInFlight = NO;
        return;
    }
    if (target.artworkImage && !_artworkIsFallback) {
        _artworkURLInFlight = NO;
        return;
    }
    NSString *urlStr = urls[idx];
    BOOL isYTFallback = [urlStr containsString:@"i.ytimg.com/vi/"];
    // Give MPMediaItemArtwork / googleusercontent a brief head start before falling back to 4:3 i.ytimg.com on songs
    if (isYTFallback && target.artworkImage) {
        _artworkURLInFlight = NO;
        return;
    }

    UIImage *cached = [_artCache objectForKey:urlStr];
    if (cached) {
        _artworkURLInFlight = NO;
        if (!target.artworkURL.length) target.artworkURL = urlStr;
        [self applyArtwork:cached isFallback:isYTFallback forTrack:target];
        return;
    }

    NSURL *u = [NSURL URLWithString:urlStr];
    if (!u) {
        [self downloadThumbCandidates:urls index:idx + 1 forTrack:target];
        return;
    }

    _artworkURLInFlight = YES;
    __weak typeof(self) ws = self;
    [[[NSURLSession sharedSession] dataTaskWithURL:u completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSInteger status = [resp isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)resp).statusCode : 200;
        UIImage *img = (data.length > 0 && status < 400) ? [UIImage imageWithData:data] : nil;
        if (img && img.size.width <= 1) img = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) ss = ws;
            if (!ss || ss.track != target) { if (ss) ss->_artworkURLInFlight = NO; return; }
            if (img) {
                [ss->_artCache setObject:img forKey:urlStr];
                ss->_artworkURLInFlight = NO;
                if (!isYTFallback || !target.artworkURL.length) target.artworkURL = urlStr;
                [ss applyArtwork:img isFallback:isYTFallback forTrack:target];
            } else {
                [ss downloadThumbCandidates:urls index:idx + 1 forTrack:target];
            }
        });
    }] resume];
}

/// Continuously polls both MPMediaItemArtwork (same source as Lock Screen) and YTPlayerViewController thumbnails
/// until crisp artwork is secured — works identically whether the track has lyrics or not.
- (void)ensureArtworkForTrack:(IVLTrack *)target attempt:(NSInteger)attempt {
    if (self.track != target) return;
    if (target.artworkImage && !_artworkIsFallback) return;

    // 1. Check MPMediaItemArtwork across originalInfo / _npInfo / defaultCenter
    UIImage *npImg = [self probeSystemArtworkForTrack:target];
    if (npImg) {
        [self applyArtwork:npImg isFallback:NO forTrack:target];
        return;
    }

    // 2. Check YTPlayerViewController thumbnail URLs (and update youtubeVideoID if player caught up)
    NSString *pTitle = nil, *pArtist = nil, *pVid = nil, *pThumb = nil;
    CGFloat pDuration = 0;
    [self readPlayerTitle:&pTitle artist:&pArtist vid:&pVid thumb:&pThumb duration:&pDuration];
    BOOL sameLen = pDuration > 0 && target.duration > 0 && fabs(pDuration - target.duration) < 2.0;
    BOOL playerMatches = pVid.length && ([pVid isEqualToString:target.youtubeVideoID ?: @""] || IVLLooseEqual(pTitle, target.title) || (pTitle.length && sameLen));
    if (playerMatches) {
        if (!target.youtubeVideoID.length) {
            _committedPlayerVid = pVid;
            target.videoID = pVid;
            target.youtubeVideoID = pVid;
        }
        if (pThumb.length && !target.artworkURL.length) {
            target.artworkURL = pThumb;
        }
    }

    if (!_artworkURLInFlight) {
        NSString *rawURL = target.artworkURL;
        NSString *fallbackVid = (attempt >= 2) ? (target.youtubeVideoID ?: (playerMatches ? pVid : nil)) : nil;
        NSArray<NSString *> *candidates = IVLCandidateThumbURLs(rawURL, fallbackVid);
        if (candidates.count) {
            [self downloadThumbCandidates:candidates index:0 forTrack:target];
        } else if (attempt >= 3 && !target.youtubeVideoID.length && !_vidSearchInFlight) {
            _vidSearchInFlight = YES;
            __weak typeof(self) ws = self;
            [[IVLLyricsService shared] youtubeVideoIDForTrack:target completion:^(NSString *foundVid) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(ws) ss = ws;
                    if (!ss || ss.track != target) return;
                    ss->_vidSearchInFlight = NO;
                    if (foundVid.length == 11) {
                        if (!target.youtubeVideoID.length) target.youtubeVideoID = foundVid;
                        [ss downloadThumbCandidates:IVLCandidateThumbURLs(target.artworkURL, foundVid) index:0 forTrack:target];
                    }
                });
            }];
        }
    }

    if (attempt >= 14) return;
    static const double delays[] = { 0.08, 0.15, 0.25, 0.40, 0.60, 0.85, 1.2, 1.6, 2.2, 3.0, 4.0, 5.0, 6.5, 8.0 };
    double delay = delays[MIN((NSInteger)(sizeof(delays) / sizeof(delays[0])) - 1, MAX(0, attempt))];
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [ws ensureArtworkForTrack:target attempt:attempt + 1];
    });
}

- (void)ensureArtworkNow {
    if (self.track && (!self.track.artworkImage || _artworkIsFallback)) {
        [self ensureArtworkForTrack:self.track attempt:0];
    }
}

#pragma mark - Track detection

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

        // ALWAYS check for newly arrived MPMediaItemArtwork on every setNowPlayingInfo: call for the
        // current song (YouTube Music sets title/artist first, then sets artwork on a later call!).
        double nDur = [copy[MPMediaItemPropertyPlaybackDuration] doubleValue];
        BOOL sameDurAsCurrent = (self.track && nDur > 0 && self.track.duration > 0 && fabs(nDur - self.track.duration) < 2.5);
        BOOL movedOffStale = ![key isEqualToString:self->_staleNPKey ?: @""];
        if (self.track && (IVLLooseEqual(self.track.title, title) || [key isEqualToString:self->_committedNPKey ?: @""] || (movedOffStale && sameDurAsCurrent && self.track.youtubeVideoID.length > 0 && !self->_committedNPKey.length))) {
            self->_npKey = key;
            self->_committedNPKey = key;
            if (!self.track.artworkImage || self->_artworkIsFallback) {
                UIImage *img = IVLExtractNPArtwork(copy[MPMediaItemPropertyArtwork]);
                if (!img) img = [self probeSystemArtworkForTrack:self.track];
                if (img) [self applyArtwork:img isFallback:NO forTrack:self.track];
            }
            if (self.track.duration <= 0 && nDur > 0) {
                self.track.duration = nDur;
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
    NSDictionary *info = ([IVLLockScreen shared].originalInfo ?: [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo);
    if (info.count) [self nowPlayingInfoDidChange:info];
    if (!self.track) [self resolveImmediately];
    else [self ensureArtworkNow];
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

- (void)upgradeVideoIDForTrack:(IVLTrack *)target attempt:(NSInteger)attempt {
    if (self.track != target || target.youtubeVideoID.length == 11 || attempt >= 16) return;
    NSString *pTitle = nil, *pArtist = nil, *pVid = nil, *pThumb = nil;
    CGFloat pDuration = 0;
    [self readPlayerTitle:&pTitle artist:&pArtist vid:&pVid thumb:&pThumb duration:&pDuration];
    BOOL sameLen = pDuration > 0 && target.duration > 0 && fabs(pDuration - target.duration) < 2.0;
    if (pVid.length && (IVLLooseEqual(pTitle, target.title) || (pTitle.length && sameLen))) {
        _committedPlayerVid = pVid;
        target.videoID = pVid;
        target.youtubeVideoID = pVid;
        if (pThumb.length && !target.artworkURL.length) target.artworkURL = pThumb;
        [self ensureArtworkForTrack:target attempt:1];
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

    NSDictionary *np = [IVLLockScreen shared].originalInfo ?: (_npInfo ?: [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo);
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
        if (pTitle.length) {
            title = pTitle;
            artist = pArtist ?: @"";
            duration = pDuration > 0 ? pDuration : 0;
            vid = pVid;
            useNPArt = NO;
            _staleNPKey = npKey;
            _committedNPKey = nil;
            _committedPlayerVid = pVid;
        } else if (attempt < 16) {
            retryFast();
            return;
        } else {
            return;
        }
    } else if (npIsNew) {
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
        if (useNPArt) {
            _staleNPKey = nil;
            if (duration > 0 && self.track.duration <= 0) self.track.duration = duration;
            if (!self.track.artworkImage || _artworkIsFallback) {
                UIImage *img = IVLExtractNPArtwork(np[MPMediaItemPropertyArtwork]);
                if (img) [self applyArtwork:img isFallback:NO forTrack:self.track];
                else [self ensureArtworkForTrack:self.track attempt:0];
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
    if (vid.length && pThumb.length) {
        t.artworkURL = pThumb;
    }
    if (useNPArt) {
        UIImage *img = IVLExtractNPArtwork(np[MPMediaItemPropertyArtwork]);
        if (img) t.artworkImage = img;
    }

    _lastRaw = 0;
    _lastRawChange = CACurrentMediaTime();
    _artworkIsFallback = NO;
    _artworkURLInFlight = NO;
    _vidSearchInFlight = NO;
    if (useNPArt) _staleNPKey = nil;
    self.track = t;
    self.lyrics = nil;
    [[NSNotificationCenter defaultCenter] postNotificationName:IVLTrackDidChangeNotification object:self];
    [self ensureArtworkForTrack:t attempt:0];
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
