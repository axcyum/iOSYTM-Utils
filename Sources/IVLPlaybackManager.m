#import "IVLPlaybackManager.h"
#import "IVLLyricsService.h"
#import "IVLTranslator.h"
#import "IVLSettings.h"
#import "YTMHeaders.h"
#import <QuartzCore/QuartzCore.h>

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
    NSString *_pendingVideoID;
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
        if ([IVLSettings boolForKey:IVLKeyEnabled] && self.player && !self.track) [self playerDidActivateVideo:self.player];
        return;
    }
    if ([key isEqualToString:IVLKeyTranslation] || [key isEqualToString:IVLKeyTranslationLang] || [key isEqualToString:IVLKeyPronunciation]) {
        [self refreshExtras];
    } else if ([key isEqualToString:IVLKeyProviderUnison] || [key isEqualToString:IVLKeyProviderLRCLIB] || [key isEqualToString:IVLKeyProviderOrder]) {
        if (self.state == IVLLyricsStateNotFound || self.state == IVLLyricsStateError) [self reloadLyrics];
    }
}

#pragma mark - Track detection

- (void)playerDidActivateVideo:(UIViewController *)player {
    self.player = player;
    if (![IVLSettings boolForKey:IVLKeyEnabled]) return;
    _pendingVideoID = [self playerVideoID];
    NSUInteger gen = ++_generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self resolveTrackAttempt:0 generation:gen];
    });
}

- (void)playerHeartbeat:(UIViewController *)player {
    // Fallback for app versions where didActivateVideo is not delivered.
    if (!self.player) self.player = player;
    if (player != self.player || ![IVLSettings boolForKey:IVLKeyEnabled]) return;
    NSString *vid = [self playerVideoID];
    if (!vid.length || [vid isEqualToString:self.track.videoID] || [vid isEqualToString:_pendingVideoID]) return;
    [self playerDidActivateVideo:player];
}

- (NSString *)playerVideoID {
    YTPlayerViewController *p = (YTPlayerViewController *)self.player;
    NSString *vid = nil;
    if ([p respondsToSelector:@selector(currentVideoID)]) vid = [p currentVideoID];
    if (!vid.length && [p respondsToSelector:@selector(contentVideoID)]) vid = p.contentVideoID;
    return vid;
}

- (void)resolveTrackAttempt:(NSInteger)attempt generation:(NSUInteger)gen {
    if (gen != _generation) return;
    YTPlayerViewController *p = (YTPlayerViewController *)self.player;
    if (!p) return;

    NSString *vid = [self playerVideoID];
    YTIVideoDetails *details = nil;
    @try {
        if ([p respondsToSelector:@selector(playerResponse)]) {
            YTPlayerResponse *resp = p.playerResponse;
            if ([resp respondsToSelector:@selector(playerData)]) {
                YTIPlayerResponse *data = resp.playerData;
                if ([data respondsToSelector:@selector(videoDetails)]) details = data.videoDetails;
            }
        }
    } @catch (__unused NSException *e) {}

    NSString *title = [details respondsToSelector:@selector(title)] ? details.title : nil;
    NSString *artist = [details respondsToSelector:@selector(author)] ? details.author : nil;
    if (!vid.length && [details respondsToSelector:@selector(videoId)]) vid = details.videoId;
    CGFloat duration = [p respondsToSelector:@selector(currentVideoTotalMediaTime)] ? p.currentVideoTotalMediaTime : 0;

    BOOL detailsMatch = vid.length && title.length;
    if ([details respondsToSelector:@selector(videoId)] && details.videoId.length && vid.length) {
        detailsMatch = detailsMatch && [details.videoId isEqualToString:vid];   // response may still be the previous song
    }
    if ((!detailsMatch && attempt < 20) || (duration <= 0 && attempt < 8)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self resolveTrackAttempt:attempt + 1 generation:gen];
        });
        return;
    }
    if (!vid.length || !title.length) return;
    if ([self.track.videoID isEqualToString:vid]) return;

    IVLTrack *t = [IVLTrack new];
    t.videoID = vid;
    t.title = title;
    t.artist = artist ?: @"";
    t.duration = duration;
    @try {
        NSArray *thumbs = details.thumbnail.thumbnailsArray;
        YTIThumbnailDetails_Thumbnail *thumb = thumbs.lastObject;
        if ([thumb respondsToSelector:@selector(URL)]) {
            NSString *url = thumb.URL;
            // request a larger square artwork from googleusercontent ("=w120-h120-..." / "w120-h120")
            url = [url stringByReplacingOccurrencesOfString:@"w\\d+-h\\d+" withString:@"w720-h720" options:NSRegularExpressionSearch range:NSMakeRange(0, url.length)];
            t.artworkURL = url;
        }
    } @catch (__unused NSException *e) {}

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
    if (![p respondsToSelector:@selector(currentVideoMediaTime)]) return 0;
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
