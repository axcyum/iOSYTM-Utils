// LyricsPlus and Lyrically (Paxsenix) providers.
// Ported from ivLyrics' Addon_Lyrics_LyricsPlus.js and Addon_Lyrics_Paxsenix.js.

#import "IVLLyricsService+Private.h"
#import "IVLLyricsParser.h"

static NSString *const kLyricallyBase = @"https://lyrics.paxsenix.org";
static NSString *const kCatalogSearch = @"https://itunes.apple.com/search";

#pragma mark - Helpers

static NSString *IVLString(id v) { return [v isKindOfClass:[NSString class]] ? v : nil; }
static NSDictionary *IVLDict(id v) { return [v isKindOfClass:[NSDictionary class]] ? v : nil; }
static NSArray *IVLArray(id v) { return [v isKindOfClass:[NSArray class]] ? v : nil; }

/// Milliseconds from a JSON number/string, -1 when missing.
static NSInteger IVLMs(id v) {
    if ([v isKindOfClass:[NSNumber class]] || ([v isKindOfClass:[NSString class]] && [v length])) {
        double d = [v doubleValue];
        if (isfinite(d)) return MAX(0, (NSInteger)llround(d));
    }
    return -1;
}

static NSString *IVLCollapse(NSString *s) {
    if (!s.length) return @"";
    return [[s stringByReplacingOccurrencesOfString:@"[\\s\\u00A0]+" withString:@" " options:NSRegularExpressionSearch range:NSMakeRange(0, s.length)]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

/// One layer of XML character references (&amp; &#39; &#x27; ...)
static NSString *IVLDecodeEntities(NSString *s) {
    if (![s containsString:@"&"]) return s ?: @"";
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ re = [NSRegularExpression regularExpressionWithPattern:@"&(?:#([0-9]+)|#[xX]([0-9a-fA-F]+)|([a-z]+));" options:0 error:nil]; });
    NSDictionary *named = @{ @"amp": @"&", @"apos": @"'", @"gt": @">", @"lt": @"<", @"quot": @"\"" };
    NSMutableString *out = [NSMutableString string];
    __block NSUInteger last = 0;
    [re enumerateMatchesInString:s options:0 range:NSMakeRange(0, s.length) usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f, BOOL *stop) {
        [out appendString:[s substringWithRange:NSMakeRange(last, m.range.location - last)]];
        NSString *rep = nil;
        if ([m rangeAtIndex:3].location != NSNotFound) {
            rep = named[[s substringWithRange:[m rangeAtIndex:3]]];
        } else {
            BOOL dec = [m rangeAtIndex:1].location != NSNotFound;
            NSString *num = [s substringWithRange:[m rangeAtIndex:dec ? 1 : 2]];
            unsigned long long cp = 0;
            if (dec) cp = strtoull(num.UTF8String, NULL, 10);
            else [[NSScanner scannerWithString:num] scanHexLongLong:&cp];
            if (cp > 0 && cp <= 0x10FFFF && !(cp >= 0xD800 && cp <= 0xDFFF)) {
                UTF32Char c = (UTF32Char)cp;
                rep = [[NSString alloc] initWithBytes:&c length:4 encoding:NSUTF32LittleEndianStringEncoding];
            }
        }
        [out appendString:rep ?: [s substringWithRange:m.range]];
        last = NSMaxRange(m.range);
    }];
    [out appendString:[s substringFromIndex:last]];
    return out;
}

static NSString *IVLComparable(NSString *s) {
    if (!s.length) return @"";
    s = [[[s precomposedStringWithCompatibilityMapping] lowercaseString] stringByFoldingWithOptions:NSDiacriticInsensitiveSearch locale:nil];
    NSArray *parts = [s componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]];
    NSMutableArray *kept = [NSMutableArray array];
    for (NSString *p in parts) if (p.length) [kept addObject:p];
    return [kept componentsJoinedByString:@" "];
}

static double IVLTokenOverlap(NSString *a, NSString *b) {
    NSMutableSet *l = [NSMutableSet set], *r = [NSMutableSet set];
    for (NSString *t in [a componentsSeparatedByString:@" "]) if (t.length > 1) [l addObject:t];
    for (NSString *t in [b componentsSeparatedByString:@" "]) if (t.length > 1) [r addObject:t];
    if (!l.count || !r.count) return 0;
    NSUInteger m = 0;
    for (NSString *t in l) if ([r containsObject:t]) m++;
    return (double)m / (double)MAX(1, MIN(l.count, r.count));
}

static double IVLScoreText(NSString *expected, NSString *actual, double weight) {
    NSString *l = IVLComparable(expected), *r = IVLComparable(actual);
    if (!l.length || !r.length) return 0;
    if ([l isEqualToString:r]) return weight;
    if ([l containsString:r] || [r containsString:l]) return weight * 0.78;
    return weight * 0.62 * IVLTokenOverlap(l, r);
}

/// Candidate = @{ id, title, artist, duration(seconds) }  — same scoring idea as ivLyrics' Paxsenix addon.
NSDictionary *IVLBestCandidate(NSArray<NSDictionary *> *candidates, IVLTrack *track) {
    NSString *title = [IVLLyricsService cleanTitle:track.title];
    NSString *artist = [IVLLyricsService cleanArtist:track.artist];
    NSDictionary *best = nil;
    double bestScore = -1e9;
    for (NSDictionary *c in candidates) {
        if (![c[@"id"] length]) continue;
        double score = IVLScoreText(title, [IVLLyricsService cleanTitle:c[@"title"]], 70);
        if ([IVLComparable(title) isEqualToString:IVLComparable(c[@"title"])]) score += 18;
        double artistScore = IVLScoreText(artist, c[@"artist"], 30);
        score += artistScore;

        double diff = -1;
        id durObj = c[@"duration"];
        double cd = [durObj respondsToSelector:@selector(doubleValue)] ? [durObj doubleValue] : 0.0;
        if (track.duration > 0 && cd > 0) {
            diff = fabs(track.duration - cd);
            if (diff <= 2) score += 24;
            else if (diff <= 5) score += 18;
            else if (diff <= 15) score += 8;
            else if (diff > 60) score -= 20;
        }
        // Artist names are often in a different script (e.g. 星宮とと / Hoshimiya Toto):
        // only punish hard when the duration does not back the match up either.
        if (artist.length && artistScore == 0) score -= (diff >= 0 && diff <= 5) ? 30 : 72;

        if (score > bestScore) { bestScore = score; best = c; }
    }
    return bestScore >= 45 ? best : nil;
}

static NSInteger IVLQuality(IVLLyrics *ly) {
    if (!ly.lines.count) return 0;
    if (ly.karaoke) return 3;
    return ly.synced ? 2 : 1;
}

static IVLLyrics *IVLPlainFromTexts(NSArray<NSString *> *texts) {
    return [IVLLyricsParser parsePlain:[texts componentsJoinedByString:@"\n"]];
}

#pragma mark - Credit / placeholder lines (KuGou payloads)

static BOOL IVLIsCreditLine(NSString *text, NSUInteger index, IVLTrack *track) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"^\\s*(作词|作詞|作曲|编曲|編曲|词|詞|曲|制作人|製作人|制作|製作|监制|監製|混音|和声|和聲|吉他|贝斯|貝斯|鼓|弦乐|弦樂|录音|錄音|母带|母帶|出品|发行|發行|策划|企划|OP|SP|Lyrics?|Lyricist|Composer|Composed|Written|Arranged|Arranger|Producer|Produced|Mixed|Mastered|Vocal|Vocals)\\s*(by)?\\s*[:：]"
                                                   options:NSRegularExpressionCaseInsensitive error:nil];
    });
    if ([re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)]) return YES;
    if ([text hasPrefix:@"©"] || [text hasPrefix:@"℗"]) return YES;
    if (index == 0 && [text containsString:@" - "]) {
        NSString *t = IVLComparable([IVLLyricsService cleanTitle:track.title]);
        if (t.length && [IVLComparable(text) containsString:t]) return YES;
    }
    return NO;
}

static BOOL IVLIsNoLyricsPlaceholder(NSString *text) {
    for (NSString *p in @[@"纯音乐", @"純音樂", @"暂无歌词", @"暫無歌詞", @"没有歌词", @"沒有歌詞"]) {
        if ([text containsString:p]) return YES;
    }
    return NO;
}

@implementation IVLLyricsService (ExtraProviders)

#pragma mark - LyricsPlus

+ (IVLLyrics *)parseLyricsPlus:(NSDictionary *)payload durationMs:(NSInteger)durMs {
    NSArray *raw = IVLArray(payload[@"lyrics"]);
    if (!raw.count) return nil;
    NSString *type = [IVLString(payload[@"type"]) lowercaseString] ?: @"";
    BOOL plain = [@[@"none", @"plain", @"unsynced"] containsObject:type];
    BOOL lineOnly = [type isEqualToString:@"line"];

    NSMutableArray<IVLLyricLine *> *lines = [NSMutableArray array];
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    NSString *primarySinger = nil;
    BOOL anyTimed = NO;

    for (id item in raw) {
        NSDictionary *src = IVLDict(item);
        if (!src) continue;
        NSInteger start = IVLMs(src[@"time"]);
        NSInteger dur = IVLMs(src[@"duration"]);

        NSMutableArray<IVLWord *> *words = [NSMutableArray array];
        for (id s in IVLArray(src[@"syllabus"])) {
            NSDictionary *syl = IVLDict(s);
            if (!syl || [syl[@"isBackground"] boolValue]) continue;   // background vocals overlap the lead line
            NSInteger st = IVLMs(syl[@"time"]);
            NSString *t = IVLString(syl[@"text"]);
            if (st < 0 || !t.length) continue;
            NSInteger sd = MAX(1, IVLMs(syl[@"duration"]));
            [words addObject:[IVLWord wordWithText:t start:st end:st + sd]];
        }

        NSString *text = words.count ? [IVLLyricsParser normalizeWords:words] : IVLCollapse(IVLString(src[@"text"]));
        if (!text.length) continue;
        [texts addObject:text];

        IVLLyricLine *l = [IVLLyricLine new];
        if (start < 0 && words.count) start = words.firstObject.startMs;
        l.startMs = MAX(0, start);
        l.endMs = (start >= 0 && dur > 0) ? start + dur : 0;
        if (words.count) {
            l.startMs = MIN(l.startMs, words.firstObject.startMs);
            l.endMs = MAX(l.endMs, words.lastObject.endMs);
        }
        if (l.startMs > 0) anyTimed = YES;
        l.text = text;
        if (!plain && !lineOnly && words.count) l.words = words;

        NSString *singer = IVLString(IVLDict(src[@"element"])[@"singer"]);
        if (singer.length) {
            if (!primarySinger) primarySinger = singer;
            l.alternateVoice = ![singer isEqualToString:primarySinger];
        }
        [lines addObject:l];
    }
    if (!lines.count) return nil;
    if (plain || !anyTimed) return IVLPlainFromTexts(texts);
    return [IVLLyricsParser lyricsWithTimedLines:lines durationMs:durMs explicitEnds:YES];
}

- (void)lyricsPlusForTrack:(IVLTrack *)track completion:(IVLLyricsCompletion)done {
    NSString *title = [IVLLyricsService cleanTitle:track.title];
    NSString *artist = [IVLLyricsService artistCandidates:track.artist].firstObject ?: track.artist;
    if (!title.length || !artist.length) { done(nil, nil); return; }

    NSMutableDictionary *q = [@{ @"title": title, @"artist": artist } mutableCopy];
    if (track.duration > 0) q[@"duration"] = [NSString stringWithFormat:@"%ld", (long)llround(track.duration)];

    // Two mirrors, rotated per request like ivLyrics
    NSArray *bases = @[@"https://lyricsplus.prjktla.my.id", @"https://lyrics.geeked.wtf"];
    static NSUInteger rotation = 0;
    NSUInteger first = rotation++ % bases.count;
    NSArray<NSURL *> *urls = @[
        [IVLLyricsService URLWithBase:bases[first] path:@"/v2/lyrics/get" query:q],
        [IVLLyricsService URLWithBase:bases[(first + 1) % bases.count] path:@"/v2/lyrics/get" query:q],
    ];
    [self lyricsPlusTry:urls index:0 durationMs:(NSInteger)(track.duration * 1000) lastError:nil completion:done];
}

- (void)lyricsPlusTry:(NSArray<NSURL *> *)urls index:(NSUInteger)i durationMs:(NSInteger)durMs lastError:(NSError *)lastError completion:(IVLLyricsCompletion)done {
    if (i >= urls.count) { done(nil, lastError); return; }
    [self getJSON:urls[i] completion:^(id json, NSInteger status, NSError *error) {
        NSDictionary *payload = IVLDict(json);
        if (status == 200 && payload && !payload[@"error"]) {
            IVLLyrics *ly = [IVLLyricsService parseLyricsPlus:payload durationMs:durMs];
            if (ly) { ly.source = @"LyricsPlus"; done(ly, nil); return; }
            // a valid but empty answer means "not found" on every mirror
            if (IVLArray(payload[@"lyrics"])) { done(nil, nil); return; }
        }
        // a mirror that answers 404 knows the song is missing: that wins over another mirror being offline
        if (status == 404) { done(nil, nil); return; }
        [self lyricsPlusTry:urls index:i + 1 durationMs:durMs lastError:(error ?: lastError) completion:done];
    }];
}

#pragma mark - Lyrically (Paxsenix)

+ (NSMutableArray<IVLWord *> *)lyricallyTokens:(NSArray *)items lineStart:(NSInteger)lineStart lineEnd:(NSInteger)lineEnd {
    NSMutableArray<IVLWord *> *words = [NSMutableArray array];
    static NSRegularExpression *noSpaceBefore, *noSpaceAfter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        noSpaceBefore = [NSRegularExpression regularExpressionWithPattern:@"^(\\s|['’,.;:!?%)\\]}])" options:0 error:nil];
        noSpaceAfter = [NSRegularExpression regularExpressionWithPattern:@"[-‐‑‒–—'’]$" options:0 error:nil];
    });
    for (NSUInteger i = 0; i < items.count; i++) {
        NSDictionary *item = IVLDict(items[i]);
        NSString *text = IVLDecodeEntities(IVLString(item[@"text"]) ?: @"");
        if (!text.length) continue;
        NSDictionary *next = i + 1 < items.count ? IVLDict(items[i + 1]) : nil;
        NSString *nextText = next ? IVLDecodeEntities(IVLString(next[@"text"]) ?: @"") : nil;

        // `part == false` marks the end of a word: restore the space the API omits
        id part = item[@"part"];
        if ([part isKindOfClass:[NSNumber class]] && ![part boolValue] && nextText.length
            && ![text hasSuffix:@" "]
            && ![noSpaceBefore firstMatchInString:nextText options:0 range:NSMakeRange(0, nextText.length)]
            && ![noSpaceAfter firstMatchInString:text options:0 range:NSMakeRange(0, text.length)]) {
            text = [text stringByAppendingString:@" "];
        }

        NSInteger start = IVLMs(item[@"timestamp"]);
        if (start < 0) start = lineStart;
        NSInteger end = IVLMs(item[@"endtime"]);
        if (end < 0) end = next ? IVLMs(next[@"timestamp"]) : -1;
        if (end < 0) end = lineEnd;
        if (lineEnd > 0) end = MIN(end, lineEnd);
        [words addObject:[IVLWord wordWithText:text start:start end:MAX(start + 1, end)]];
    }
    return words;
}

+ (IVLLyrics *)parseLyrically:(NSDictionary *)payload durationMs:(NSInteger)durMs track:(IVLTrack *)track {
    NSArray *raw = IVLArray(payload[@"lyrics"]);
    if (raw.count) {
        NSString *sync = [IVLString(payload[@"syncType"]) lowercaseString] ?: @"";
        BOOL syllable = [sync isEqualToString:@"syllable"];
        BOOL none = [sync isEqualToString:@"none"];

        NSString *primaryAgent = IVLString(IVLDict(IVLArray(IVLDict(payload[@"metadata"])[@"agents"]).firstObject)[@"id"]);
        NSMutableArray<IVLLyricLine *> *lines = [NSMutableArray array];
        NSMutableArray<NSString *> *texts = [NSMutableArray array];
        BOOL leading = YES;

        for (NSUInteger idx = 0; idx < raw.count; idx++) {
            NSDictionary *line = IVLDict(raw[idx]);
            if (!line) continue;
            NSArray *tokens = IVLArray(line[@"text"]);
            NSInteger start = IVLMs(line[@"timestamp"]);
            if (start < 0) start = IVLMs(IVLDict(tokens.firstObject)[@"timestamp"]);
            if (start < 0) start = 0;
            NSInteger end = IVLMs(line[@"endtime"]);
            if (end < 0) end = IVLMs(IVLDict(tokens.lastObject)[@"endtime"]);
            if (end < 0) end = 0;

            NSMutableArray<IVLWord *> *words = tokens ? [self lyricallyTokens:tokens lineStart:start lineEnd:end] : [NSMutableArray array];
            NSString *text = words.count ? [IVLLyricsParser normalizeWords:words] : IVLCollapse(IVLDecodeEntities(IVLString(line[@"text"]) ?: @""));
            if (!text.length) continue;

            // Leading title/credit lines (mostly KuGou)
            if (leading && idx < 10 && IVLIsCreditLine(text, idx, track)) continue;
            leading = NO;

            IVLLyricLine *l = [IVLLyricLine new];
            l.startMs = start;
            l.endMs = end;
            l.text = text;
            if (syllable && words.count) l.words = words;
            NSString *agent = IVLString(line[@"agent"]);
            if (agent.length && !primaryAgent) primaryAgent = agent;
            l.alternateVoice = (agent.length && ![agent isEqualToString:primaryAgent]) || [line[@"oppositeTurn"] boolValue];
            [lines addObject:l];
            [texts addObject:text];
        }

        if (!lines.count) return nil;
        if (lines.count <= 3) {
            BOOL allPlaceholder = YES;
            for (NSString *t in texts) if (!IVLIsNoLyricsPlaceholder(t)) { allPlaceholder = NO; break; }
            if (allPlaceholder) return nil;
        }
        if (none) return IVLPlainFromTexts(texts);
        if (durMs <= 0) durMs = MAX(0, IVLMs(IVLDict(payload[@"metadata"])[@"duration"]));
        return [IVLLyricsParser lyricsWithTimedLines:lines durationMs:durMs explicitEnds:YES];
    }

    NSString *ttml = IVLString(payload[@"ttmlContent"]);
    if (ttml.length) return [IVLLyricsParser parseTTML:ttml durationMs:durMs];
    NSString *lrc = IVLString(payload[@"lrc"]);
    if (lrc.length) return [IVLLyricsParser parseLRC:IVLDecodeEntities(lrc) durationMs:durMs];
    NSString *plain = IVLString(payload[@"plain"]);
    if (plain.length) return [IVLLyricsParser parsePlain:plain];
    return nil;
}

/// Apple Music catalog route: iTunes search -> Lyrically apple-music/lyrics
- (void)lyricallyCatalog:(IVLTrack *)track term:(NSString *)term durationMs:(NSInteger)durMs completion:(IVLLyricsCompletion)done {
    NSURL *search = [IVLLyricsService URLWithBase:kCatalogSearch path:@"" query:@{ @"term": term, @"entity": @"song", @"limit": @"25" }];
    [self getJSON:search completion:^(id json, NSInteger status, NSError *error) {
        NSMutableArray *cands = [NSMutableArray array];
        for (id r in IVLArray(IVLDict(json)[@"results"])) {
            NSDictionary *d = IVLDict(r);
            if (!d[@"trackId"]) continue;
            id msObj = d[@"trackTimeMillis"];
            double sec = [msObj respondsToSelector:@selector(doubleValue)] ? ([msObj doubleValue] / 1000.0) : 0.0;
            [cands addObject:@{ @"id": [d[@"trackId"] description],
                                @"title": IVLString(d[@"trackName"]) ?: @"",
                                @"artist": IVLString(d[@"artistName"]) ?: @"",
                                @"duration": @(sec) }];
        }
        NSDictionary *best = IVLBestCandidate(cands, track);
        if (!best) { done(nil, error); return; }
        NSURL *u = [IVLLyricsService URLWithBase:kLyricallyBase path:@"/apple-music/lyrics" query:@{ @"id": best[@"id"], @"v": @"2" }];
        [self getJSON:u completion:^(id j2, NSInteger s2, NSError *e2) {
            IVLLyrics *ly = s2 == 200 && IVLDict(j2) ? [IVLLyricsService parseLyrically:j2 durationMs:durMs track:track] : nil;
            done(ly, ly ? nil : e2);
        }];
    }];
}

/// KuGou route: Lyrically kugou/search -> kugou/lyrics
- (void)lyricallyKugou:(IVLTrack *)track term:(NSString *)term durationMs:(NSInteger)durMs completion:(IVLLyricsCompletion)done {
    NSURL *search = [IVLLyricsService URLWithBase:kLyricallyBase path:@"/kugou/search" query:@{ @"q": term }];
    [self getJSON:search completion:^(id json, NSInteger status, NSError *error) {
        NSMutableArray *cands = [NSMutableArray array];
        for (id r in IVLArray(json)) {
            NSDictionary *d = IVLDict(r);
            NSString *hash = [d[@"hash"] description];
            if (!hash.length) continue;
            id durObj = d[@"duration"];
            double sec = [durObj respondsToSelector:@selector(doubleValue)] ? [durObj doubleValue] : 0.0;
            [cands addObject:@{ @"id": hash, @"title": IVLString(d[@"title"]) ?: @"", @"artist": IVLString(d[@"artist"]) ?: @"",
                                @"duration": @(sec) }];
        }
        NSDictionary *best = IVLBestCandidate(cands, track);
        if (!best) { done(nil, error); return; }
        [self lyricallyKugouLyrics:best[@"id"] attempt:0 track:track durationMs:durMs completion:done];
    }];
}

/// word=false first: that response still carries syllable timings plus the original text
- (void)lyricallyKugouLyrics:(NSString *)hash attempt:(NSUInteger)attempt track:(IVLTrack *)track durationMs:(NSInteger)durMs completion:(IVLLyricsCompletion)done {
    if (attempt >= 2) { done(nil, nil); return; }
    NSURL *u = [IVLLyricsService URLWithBase:kLyricallyBase path:@"/kugou/lyrics"
                                       query:@{ @"id": hash, @"word": attempt == 0 ? @"false" : @"true", @"v": @"2" }];
    [self getJSON:u completion:^(id json, NSInteger status, NSError *error) {
        IVLLyrics *ly = status == 200 && IVLArray(IVLDict(json)[@"lyrics"]).count
            ? [IVLLyricsService parseLyrically:json durationMs:durMs track:track] : nil;
        if (ly) { done(ly, nil); return; }
        [self lyricallyKugouLyrics:hash attempt:attempt + 1 track:track durationMs:durMs completion:done];
    }];
}

- (void)lyricallyForTrack:(IVLTrack *)track completion:(IVLLyricsCompletion)done {
    NSString *title = [IVLLyricsService cleanTitle:track.title];
    NSString *artist = [IVLLyricsService cleanArtist:track.artist];
    if (!title.length) { done(nil, nil); return; }
    NSString *term = artist.length ? [NSString stringWithFormat:@"%@ %@", title, artist] : title;
    NSInteger durMs = (NSInteger)(track.duration * 1000);

    // Both routes in parallel; keep the better result (word sync > line sync > plain, catalog wins ties)
    dispatch_group_t group = dispatch_group_create();
    __block IVLLyrics *catalog = nil, *kugou = nil;
    __block NSError *lastError = nil;
    dispatch_group_enter(group);
    [self lyricallyCatalog:track term:term durationMs:durMs completion:^(IVLLyrics *ly, NSError *e) {
        @synchronized (group) { catalog = ly; if (e) lastError = e; }
        dispatch_group_leave(group);
    }];
    dispatch_group_enter(group);
    [self lyricallyKugou:track term:term durationMs:durMs completion:^(IVLLyrics *ly, NSError *e) {
        @synchronized (group) { kugou = ly; if (e) lastError = e; }
        dispatch_group_leave(group);
    }];
    dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        IVLLyrics *best = IVLQuality(catalog) >= IVLQuality(kugou) ? catalog : kugou;
        if (!IVLQuality(best)) best = nil;
        best.source = @"Lyrically";
        done(best, best ? nil : lastError);
    });
}

@end
