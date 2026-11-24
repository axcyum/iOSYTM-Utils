#import "IVLLyricsService.h"
#import "IVLLyricsService+Private.h"
#import "IVLSpotify.h"
#import "IVLLyricsParser.h"
#import "IVLSettings.h"
#import <NaturalLanguage/NaturalLanguage.h>

#ifndef IVL_VERSION
#define IVL_VERSION "1.0.0"
#endif

static NSString *const kUnisonBase = @"https://unison.boidu.dev";
static NSString *const kLRCLIBBase = @"https://lrclib.net/api";
static const NSTimeInterval kDurationTolerance = 15.0;   // same as ivLyrics' LRCLIB addon


@implementation IVLSearchResult
@end

@implementation IVLLyricsService {
    NSURLSession *_session;
    NSCache<NSString *, IVLLyrics *> *_memory;
    dispatch_queue_t _io;
}

+ (instancetype)shared {
    static IVLLyricsService *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [self new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest = 10;
        cfg.HTTPAdditionalHeaders = @{
            @"User-Agent": [NSString stringWithFormat:@"ivLyricsYTM/%s (+https://github.com/ivLis-Studio/ivLyrics)", IVL_VERSION],
            @"Accept": @"application/json",
        };
        _session = [NSURLSession sessionWithConfiguration:cfg];
        _memory = [NSCache new];
        _memory.countLimit = 50;
        _io = dispatch_queue_create("ivlyrics.io", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

#pragma mark - Metadata cleaning

+ (NSString *)cleanTitle:(NSString *)title {
    if (!title.length) return @"";
    NSString *t = title;
    // (Official Video) [MV] 【Official Music Video】 (Lyrics) (Audio) (Visualizer) ...
    NSString *kw = @"(official|video|audio|lyric|lyrics|mv|m/v|visualizer|music video|performance video|full ver|4k|hd|hq)";
    NSString *pattern = [NSString stringWithFormat:@"\\s*[\\(\\[【「（][^\\)\\]】」）]*%@[^\\)\\]】」）]*[\\)\\]】」）]", kw];
    t = [t stringByReplacingOccurrencesOfString:pattern withString:@"" options:NSRegularExpressionSearch | NSCaseInsensitiveSearch range:NSMakeRange(0, t.length)];
    // (feat. X) / ft. X
    t = [t stringByReplacingOccurrencesOfString:@"\\s*[\\(\\[（](feat\\.?|ft\\.?|featuring)\\s[^\\)\\]）]*[\\)\\]）]" withString:@"" options:NSRegularExpressionSearch | NSCaseInsensitiveSearch range:NSMakeRange(0, t.length)];
    t = [t stringByReplacingOccurrencesOfString:@"\\s+(feat\\.?|ft\\.?)\\s.*$" withString:@"" options:NSRegularExpressionSearch | NSCaseInsensitiveSearch range:NSMakeRange(0, t.length)];
    t = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return t.length ? t : title;
}

+ (NSString *)cleanArtist:(NSString *)artist {
    if (!artist.length) return @"";
    NSString *a = artist;
    a = [a stringByReplacingOccurrencesOfString:@"\\s*-\\s*Topic$" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, a.length)];
    a = [a stringByReplacingOccurrencesOfString:@"VEVO$" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, a.length)];
    a = [a stringByReplacingOccurrencesOfString:@"\\s*(Official)?\\s*(YouTube)?\\s*Channel$" withString:@"" options:NSRegularExpressionSearch | NSCaseInsensitiveSearch range:NSMakeRange(0, a.length)];
    a = [a stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return a.length ? a : artist;
}

+ (NSArray<NSString *> *)artistCandidates:(NSString *)artist {
    NSMutableOrderedSet *set = [NSMutableOrderedSet orderedSet];
    NSString *clean = [self cleanArtist:artist];
    if (clean.length) [set addObject:clean];
    NSArray *seps = @[@" & ", @", ", @" x ", @" X ", @" feat. ", @" ft. ", @"、", @" and "];
    for (NSString *sep in seps) {
        NSRange r = [clean rangeOfString:sep];
        if (r.location != NSNotFound && r.location > 0) {
            [set addObject:[[clean substringToIndex:r.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
        }
    }
    return set.array;
}

/// "Artist - Song" style titles of uploaded videos
+ (nullable NSArray<NSString *> *)splitDashedTitle:(NSString *)title {
    for (NSString *sep in @[@" - ", @" – ", @" — ", @" / "]) {
        NSRange r = [title rangeOfString:sep];
        if (r.location != NSNotFound && r.location > 0 && NSMaxRange(r) < title.length) {
            return @[[title substringToIndex:r.location], [title substringFromIndex:NSMaxRange(r)]];
        }
    }
    return nil;
}

static NSString *IVLNorm(NSString *s) {
    s = [[s precomposedStringWithCompatibilityMapping] lowercaseString];
    s = [s stringByFoldingWithOptions:NSDiacriticInsensitiveSearch locale:nil];
    NSCharacterSet *keep = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    return [[s componentsSeparatedByCharactersInSet:keep] componentsJoinedByString:@""];
}

#pragma mark - Networking

- (void)getJSON:(NSURL *)url completion:(void (^)(id _Nullable json, NSInteger status, NSError *_Nullable error))completion {
    [[_session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        completion(json, status, error);
    }] resume];
}

static NSURL *IVLURL(NSString *base, NSString *path, NSDictionary<NSString *, NSString *> *query) {
    NSURLComponents *c = [NSURLComponents componentsWithString:[base stringByAppendingString:path]];
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *k in query) if (query[k].length) [items addObject:[NSURLQueryItem queryItemWithName:k value:query[k]]];
    c.queryItems = items;
    // '+' is not escaped by NSURLComponents but servers decode it as space
    c.percentEncodedQuery = [c.percentEncodedQuery stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"];
    return c.URL;
}

+ (NSURL *)URLWithBase:(NSString *)base path:(NSString *)path query:(NSDictionary<NSString *, NSString *> *)query {
    return IVLURL(base, path, query);
}

#pragma mark - Providers

- (void)unisonForTrack:(IVLTrack *)track completion:(IVLLyricsCompletion)done {
    NSString *title = [IVLLyricsService cleanTitle:track.title];
    NSArray *artists = [IVLLyricsService artistCandidates:track.artist];
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSString *dur = track.duration > 0 ? [NSString stringWithFormat:@"%ld", (long)llround(track.duration)] : nil;
    for (NSString *a in artists) {
        [urls addObject:IVLURL(kUnisonBase, @"/lyrics", @{ @"song": title, @"artist": a, @"duration": dur ?: @"" })];
    }
    if (dur && artists.count) [urls addObject:IVLURL(kUnisonBase, @"/lyrics", @{ @"song": title, @"artist": artists.firstObject })];
    [self unisonTry:urls index:0 durationMs:(NSInteger)(track.duration * 1000) completion:done];
}

- (void)unisonTry:(NSArray<NSURL *> *)urls index:(NSUInteger)i durationMs:(NSInteger)durMs completion:(IVLLyricsCompletion)done {
    if (i >= urls.count) { done(nil, nil); return; }
    [self getJSON:urls[i] completion:^(id json, NSInteger status, NSError *error) {
        NSDictionary *data = [json isKindOfClass:[NSDictionary class]] ? json[@"data"] : nil;
        NSString *lyrics = [data isKindOfClass:[NSDictionary class]] ? data[@"lyrics"] : nil;
        id success = [json isKindOfClass:[NSDictionary class]] ? json[@"success"] : nil;
        if ([lyrics isKindOfClass:[NSString class]] && lyrics.length && !(success && ![success boolValue])) {
            NSString *format = [[data[@"format"] description] lowercaseString];
            IVLLyrics *ly = nil;
            if ([format isEqualToString:@"ttml"]) ly = [IVLLyricsParser parseTTML:lyrics durationMs:durMs];
            else if ([format isEqualToString:@"lrc"]) ly = [IVLLyricsParser parseLRC:lyrics durationMs:durMs];
            else ly = [IVLLyricsParser parsePlain:lyrics];
            if (ly) { ly.source = @"Unison"; done(ly, nil); return; }
        }
        if (error && error.code != NSURLErrorCancelled && status == 0) { done(nil, error); return; }
        [self unisonTry:urls index:i + 1 durationMs:durMs completion:done];
    }];
}

- (IVLLyrics *)lyricsFromLRCLIBRecord:(NSDictionary *)rec durationMs:(NSInteger)durMs {
    if (![rec isKindOfClass:[NSDictionary class]]) return nil;
    NSString *synced = rec[@"syncedLyrics"];
    NSString *plain = rec[@"plainLyrics"];
    IVLLyrics *ly = nil;
    if ([synced isKindOfClass:[NSString class]] && synced.length) ly = [IVLLyricsParser parseLRC:synced durationMs:durMs];
    if (!ly && [plain isKindOfClass:[NSString class]] && plain.length) ly = [IVLLyricsParser parsePlain:plain];
    ly.source = @"LRCLIB";
    return ly;
}

- (NSDictionary *)bestLRCLIBRecord:(NSArray *)records track:(IVLTrack *)track title:(NSString *)title {
    NSDictionary *best = nil;
    double bestScore = -1;
    NSString *nt = IVLNorm(title);
    for (NSDictionary *r in records) {
        if (![r isKindOfClass:[NSDictionary class]] || [r[@"instrumental"] boolValue]) continue;
        double score = 0;
        double d = [r[@"duration"] doubleValue];
        if (track.duration > 0 && d > 0) {
            double diff = fabs(d - track.duration);
            if (diff > kDurationTolerance) continue;
            score += (kDurationTolerance - diff) / kDurationTolerance * 2.0;
        }
        NSString *rt = IVLNorm([r[@"trackName"] description] ?: @"");
        if (nt.length && [rt isEqualToString:nt]) score += 3;
        else if (nt.length && ([rt containsString:nt] || [nt containsString:rt])) score += 1;
        if ([r[@"syncedLyrics"] isKindOfClass:[NSString class]] && [r[@"syncedLyrics"] length]) score += 4;
        if (score > bestScore) { bestScore = score; best = r; }
    }
    return best;
}

- (void)lrclibForTrack:(IVLTrack *)track completion:(IVLLyricsCompletion)done {
    NSString *title = [IVLLyricsService cleanTitle:track.title];
    NSString *artist = [IVLLyricsService artistCandidates:track.artist].firstObject ?: track.artist;
    NSInteger durMs = (NSInteger)(track.duration * 1000);

    void (^searchFallback)(void) = ^{
        NSURL *u = IVLURL(kLRCLIBBase, @"/search", @{ @"track_name": title, @"artist_name": artist });
        [self getJSON:u completion:^(id json, NSInteger status, NSError *error) {
            NSDictionary *best = [json isKindOfClass:[NSArray class]] ? [self bestLRCLIBRecord:json track:track title:title] : nil;
            if (best) { done([self lyricsFromLRCLIBRecord:best durationMs:durMs], nil); return; }
            // free-text: also handles "Artist - Song" video titles
            NSArray *split = [IVLLyricsService splitDashedTitle:title];
            NSString *q = split ? [NSString stringWithFormat:@"%@ %@", split[1], split[0]] : [NSString stringWithFormat:@"%@ %@", title, artist];
            NSString *qTitle = split ? [IVLLyricsService cleanTitle:split[1]] : title;
            [self getJSON:IVLURL(kLRCLIBBase, @"/search", @{ @"q": q }) completion:^(id json2, NSInteger s2, NSError *e2) {
                NSDictionary *b2 = [json2 isKindOfClass:[NSArray class]] ? [self bestLRCLIBRecord:json2 track:track title:qTitle] : nil;
                done(b2 ? [self lyricsFromLRCLIBRecord:b2 durationMs:durMs] : nil, b2 ? nil : (e2 ?: error));
            }];
        }];
    };

    if (track.duration <= 0) { searchFallback(); return; }
    NSURL *get = IVLURL(kLRCLIBBase, @"/get", @{ @"track_name": title, @"artist_name": artist,
                                                  @"duration": [NSString stringWithFormat:@"%ld", (long)llround(track.duration)] });
    [self getJSON:get completion:^(id json, NSInteger status, NSError *error) {
        IVLLyrics *ly = (status == 200) ? [self lyricsFromLRCLIBRecord:json durationMs:durMs] : nil;
        if (ly) { done(ly, nil); return; }
        searchFallback();
    }];
}

- (void)invokeProvider:(NSString *)pid track:(IVLTrack *)track completion:(IVLLyricsCompletion)done {
    if ([pid isEqualToString:@"spotify"]) [[IVLSpotify shared] lyricsForTrack:track completion:done];
    else if ([pid isEqualToString:@"youtube"]) [self youtubeForTrack:track completion:done];
    else if ([pid isEqualToString:@"lyricsplus"]) [self lyricsPlusForTrack:track completion:done];
    else if ([pid isEqualToString:@"unison"]) [self unisonForTrack:track completion:done];
    else if ([pid isEqualToString:@"lyrically"]) [self lyricallyForTrack:track completion:done];
    else if ([pid isEqualToString:@"lrclib"]) [self lrclibForTrack:track completion:done];
    else done(nil, nil);
}

static BOOL IVLHasCJK(NSString *s) {
    return s.length && [s rangeOfString:@"[\\u3040-\\u30ff\\u3400-\\u4dbf\\u4e00-\\u9fff\\uac00-\\ud7af]" options:NSRegularExpressionSearch].location != NSNotFound;
}

/// Japanese/Korean/Chinese song whose lyrics came back romanized ("Yoake ga o heya o ...")
static BOOL IVLLooksRomanized(IVLLyrics *ly, IVLTrack *track) {
    if (!IVLHasCJK([NSString stringWithFormat:@"%@ %@", track.title ?: @"", track.artist ?: @""])) return NO;
    return !IVLHasCJK([ly plainText]);
}

/// word sync 30 > line sync 20 > plain 10; romanized lyrics of a CJK song drop below the next tier
static NSInteger IVLLyricsQuality(IVLLyrics *ly, IVLTrack *track) {
    if (!ly.lines.count) return 0;
    NSInteger q = ly.karaoke ? 30 : (ly.synced ? 20 : 10);
    if (IVLLooksRomanized(ly, track)) q -= 15;
    return q;
}

/// All enabled providers run in parallel. The first word-synced result in priority order wins
/// as soon as every higher-priority provider has answered; otherwise the best result
/// (word > line > plain, then priority) is taken when all are done, 3 s after the first
/// synced result arrived, or after 15 s at the latest.
- (void)runProviders:(NSArray<NSString *> *)ids track:(IVLTrack *)track completion:(IVLLyricsCompletion)done {
    NSUInteger n = ids.count;
    if (!n) { done(nil, nil); return; }
    dispatch_queue_t q = dispatch_queue_create("ivlyrics.race", DISPATCH_QUEUE_SERIAL);
    NSMutableArray *results = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray<NSNumber *> *finished = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) { [results addObject:[NSNull null]]; [finished addObject:@NO]; }
    __block BOOL decided = NO, graceArmed = NO;
    __block NSError *lastError = nil;

    __block void (^evaluate)(BOOL);
    void (^finish)(IVLLyrics *) = ^(IVLLyrics *ly) {
        decided = YES;
        done(ly, ly ? nil : lastError);
        dispatch_async(q, ^{ evaluate = nil; });   // break the self-referencing block after this call returns
    };
    void (^evaluateImpl)(BOOL) = ^(BOOL force) {
        if (decided) return;
        BOOL prefixDone = YES, allDone = YES;
        IVLLyrics *best = nil;
        NSInteger bestQ = 0;
        for (NSUInteger i = 0; i < n; i++) {
            if (![finished[i] boolValue]) { prefixDone = NO; allDone = NO; continue; }
            IVLLyrics *ly = results[i] == [NSNull null] ? nil : results[i];
            NSInteger quality = IVLLyricsQuality(ly, track);
            if (quality == 30 && prefixDone) { finish(ly); return; }
            if (quality > bestQ) { bestQ = quality; best = ly; }
        }
        if (allDone || force) { finish(best); return; }
        if (bestQ >= 20 && !graceArmed) {
            graceArmed = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), q, ^{ if (evaluate) evaluate(YES); });
        }
    };
    evaluate = evaluateImpl;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)), q, ^{ if (evaluate) evaluate(YES); });
    for (NSUInteger i = 0; i < n; i++) {
        [self invokeProvider:ids[i] track:track completion:^(IVLLyrics *ly, NSError *err) {
            dispatch_async(q, ^{
                if (ly) results[i] = ly;
                if (err && err.code != 404 && err.code != 401) lastError = err;
                finished[i] = @YES;
                if (evaluate) evaluate(NO);
            });
        }];
    }
}

#pragma mark - Public

- (void)fetchProvider:(NSString *)providerID track:(IVLTrack *)track completion:(IVLLyricsCompletion)completion {
    [self invokeProvider:providerID track:track completion:^(IVLLyrics *ly, NSError *err) {
        if (ly && !ly.language) ly.language = [IVLLyricsService detectLanguage:ly];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ly.lines.count ? ly : nil, err); });
    }];
}

- (void)lyricsForTrack:(IVLTrack *)track completion:(IVLLyricsCompletion)completion {
    IVLLyricsCompletion main = ^(IVLLyrics *ly, NSError *e) { dispatch_async(dispatch_get_main_queue(), ^{ completion(ly, e); }); };
    NSString *vid = track.videoID;
    IVLLyrics *mem = vid.length ? [_memory objectForKey:vid] : nil;
    if (mem) { main(mem, nil); return; }

    dispatch_async(_io, ^{
        IVLLyrics *disk = [self readFile:[self manualPathFor:vid]] ?: [self readFile:[self cachePathFor:vid]];
        if (disk) { [self->_memory setObject:disk forKey:vid]; main(disk, nil); return; }

        [self runProviders:[IVLSettings enabledProviderIDs] track:track completion:^(IVLLyrics *ly, NSError *err) {
            if (ly) {
                ly.language = [IVLLyricsService detectLanguage:ly];
                if (vid.length) {
                    [self->_memory setObject:ly forKey:vid];
                    dispatch_async(self->_io, ^{ [self writeLyrics:ly toPath:[self cachePathFor:vid]]; });
                }
            }
            main(ly, err);
        }];
    });
}

- (void)searchQuery:(NSString *)query completion:(void (^)(NSArray<IVLSearchResult *> *, NSError *))completion {
    [self getJSON:IVLURL(kLRCLIBBase, @"/search", @{ @"q": query ?: @"" }) completion:^(id json, NSInteger status, NSError *error) {
        NSMutableArray *results = [NSMutableArray array];
        if ([json isKindOfClass:[NSArray class]]) {
            for (NSDictionary *r in json) {
                if (![r isKindOfClass:[NSDictionary class]] || [r[@"instrumental"] boolValue]) continue;
                IVLLyrics *ly = [self lyricsFromLRCLIBRecord:r durationMs:(NSInteger)([r[@"duration"] doubleValue] * 1000)];
                if (!ly) continue;
                IVLSearchResult *res = [IVLSearchResult new];
                res.title = [r[@"trackName"] description] ?: @"";
                res.artist = [r[@"artistName"] description] ?: @"";
                res.album = [r[@"albumName"] isKindOfClass:[NSString class]] ? r[@"albumName"] : nil;
                res.duration = [r[@"duration"] doubleValue];
                res.synced = ly.synced;
                res.source = @"LRCLIB";
                res.lyrics = ly;
                [results addObject:res];
            }
            [results sortUsingComparator:^NSComparisonResult(IVLSearchResult *a, IVLSearchResult *b) {
                if (a.synced == b.synced) return NSOrderedSame;
                return a.synced ? NSOrderedAscending : NSOrderedDescending;
            }];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(results, results.count ? nil : error); });
    }];
}

- (void)saveManualLyrics:(IVLLyrics *)lyrics forVideoID:(NSString *)videoID {
    if (!videoID.length || !lyrics) return;
    lyrics.manual = YES;
    if (!lyrics.language) lyrics.language = [IVLLyricsService detectLanguage:lyrics];
    [_memory setObject:lyrics forKey:videoID];
    dispatch_async(_io, ^{ [self writeLyrics:lyrics toPath:[self manualPathFor:videoID]]; });
}

- (void)removeCachedLyricsForVideoID:(NSString *)videoID {
    if (!videoID.length) return;
    [_memory removeObjectForKey:videoID];
    dispatch_sync(_io, ^{
        [[NSFileManager defaultManager] removeItemAtPath:[self cachePathFor:videoID] error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:[self manualPathFor:videoID] error:nil];
    });
}

- (void)clearCache {
    [_memory removeAllObjects];
    dispatch_sync(_io, ^{ [[NSFileManager defaultManager] removeItemAtPath:[self cacheDir] error:nil]; });
}

- (unsigned long long)cacheSize {
    __block unsigned long long total = 0;
    dispatch_sync(_io, ^{
        NSString *dir = [self cacheDir];
        for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil]) {
            total += [[[NSFileManager defaultManager] attributesOfItemAtPath:[dir stringByAppendingPathComponent:f] error:nil] fileSize];
        }
    });
    return total;
}

#pragma mark - Language

+ (NSString *)detectLanguage:(IVLLyrics *)lyrics {
    NSString *text = [lyrics plainText];
    if (!text.length) return nil;
    NLLanguageRecognizer *r = [NLLanguageRecognizer new];
    [r processString:text.length > 4000 ? [text substringToIndex:4000] : text];
    NSString *lang = r.dominantLanguage;
    // Japanese lyrics full of kanji are sometimes classified as Chinese: kana decides.
    if ([lang hasPrefix:@"zh"] && [text rangeOfString:@"[\\u3040-\\u30ff]" options:NSRegularExpressionSearch].location != NSNotFound) lang = @"ja";
    return lang;
}

#pragma mark - Disk

- (NSString *)cacheDir {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [base stringByAppendingPathComponent:@"ivLyricsYTM/lyrics2"];   // bumped: provider selection changed
}

- (NSString *)manualDir {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [base stringByAppendingPathComponent:@"ivLyricsYTM/manual"];
}

static NSString *IVLSafeName(NSString *vid) {
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"] invertedSet];
    return [[[vid ?: @"" componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"] stringByAppendingPathExtension:@"json"];
}

- (NSString *)cachePathFor:(NSString *)vid { return vid.length ? [[self cacheDir] stringByAppendingPathComponent:IVLSafeName(vid)] : nil; }
- (NSString *)manualPathFor:(NSString *)vid { return vid.length ? [[self manualDir] stringByAppendingPathComponent:IVLSafeName(vid)] : nil; }

- (IVLLyrics *)readFile:(NSString *)path {
    if (!path) return nil;
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    return [IVLLyrics lyricsWithDictionary:json];
}

- (void)writeLyrics:(IVLLyrics *)ly toPath:(NSString *)path {
    if (!path) return;
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *d = [NSJSONSerialization dataWithJSONObject:[ly dictionaryRepresentation] options:0 error:nil];
    [d writeToFile:path atomically:YES];
}

@end
