// YouTube Music's own lyrics (the "Lyrics" tab of the app), read through the same
// InnerTube API the app uses. Mobile clients receive time-synced lines
// (timedLyricsModel); the web client only receives plain text.
// Same approach as ytmusicapi's get_lyrics(timestamps=True).

#import "IVLLyricsService+Private.h"
#import "IVLLyricsParser.h"

static NSString *const kInnerTube = @"https://music.youtube.com/youtubei/v1";

static NSDictionary *IVLYTDict(id v) { return [v isKindOfClass:[NSDictionary class]] ? v : nil; }
static NSArray *IVLYTArray(id v) { return [v isKindOfClass:[NSArray class]] ? v : nil; }
static NSString *IVLYTString(id v) { return [v isKindOfClass:[NSString class]] ? v : nil; }

/// Depth-first search (arrays in order) for the first value stored under `key`.
static id IVLYTFind(id node, NSString *key, NSUInteger depth) {
    if (depth > 40) return nil;
    if ([node isKindOfClass:[NSDictionary class]]) {
        id hit = node[key];
        if (hit) return hit;
        for (id k in node) {
            id r = IVLYTFind(node[k], key, depth + 1);
            if (r) return r;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id v in node) {
            id r = IVLYTFind(v, key, depth + 1);
            if (r) return r;
        }
    }
    return nil;
}

/// First string starting with `prefix` anywhere in the tree (used for the lyrics browseId "MPLYt...").
static NSString *IVLYTFindPrefix(id node, NSString *prefix, NSUInteger depth) {
    if (depth > 40) return nil;
    if ([node isKindOfClass:[NSString class]]) return [node hasPrefix:prefix] ? node : nil;
    if ([node isKindOfClass:[NSDictionary class]]) {
        for (id k in node) { NSString *r = IVLYTFindPrefix(node[k], prefix, depth + 1); if (r) return r; }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id v in node) { NSString *r = IVLYTFindPrefix(v, prefix, depth + 1); if (r) return r; }
    }
    return nil;
}

static NSString *IVLYTLanguage(void) {
    NSString *pref = [NSLocale preferredLanguages].firstObject ?: @"en";
    return [[pref componentsSeparatedByString:@"-"] firstObject] ?: @"en";
}

static NSString *IVLYTRegion(void) {
    NSString *r = [[NSLocale currentLocale] objectForKey:NSLocaleCountryCode];
    return r.length == 2 ? r : @"US";
}

static NSDictionary *IVLYTClient(NSString *name) {
    NSMutableDictionary *c = [@{ @"hl": IVLYTLanguage(), @"gl": IVLYTRegion() } mutableCopy];
    if ([name isEqualToString:@"ANDROID_MUSIC"]) {
        c[@"clientName"] = @"ANDROID_MUSIC"; c[@"clientVersion"] = @"7.27.52"; c[@"androidSdkVersion"] = @34;
    } else if ([name isEqualToString:@"IOS_MUSIC"]) {
        c[@"clientName"] = @"IOS_MUSIC"; c[@"clientVersion"] = @"7.27.0";
    } else {
        c[@"clientName"] = @"WEB_REMIX"; c[@"clientVersion"] = @"1.20250310.01.00";
    }
    return @{ @"client": c };
}

static NSString *IVLYTUserAgent(NSString *client) {
    if ([client isEqualToString:@"ANDROID_MUSIC"]) return @"com.google.android.apps.youtube.music/7.27.52 (Linux; U; Android 14) gzip";
    if ([client isEqualToString:@"IOS_MUSIC"]) return @"com.google.ios.youtubemusic/7.27.0 (iPhone16,2; U; CPU iOS 17_5 like Mac OS X)";
    return @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15";
}

static NSString *IVLYTNorm(NSString *s) {
    s = [[[s ?: @"" precomposedStringWithCompatibilityMapping] lowercaseString] stringByFoldingWithOptions:NSDiacriticInsensitiveSearch locale:nil];
    return [[s componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]] componentsJoinedByString:@""];
}

@implementation IVLLyricsService (YouTube)

- (void)innerTube:(NSString *)endpoint client:(NSString *)client body:(NSDictionary *)body completion:(void (^)(NSDictionary *_Nullable json))completion {
    NSMutableDictionary *payload = [body mutableCopy];
    payload[@"context"] = IVLYTClient(client);
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/%@?prettyPrint=false", kInnerTube, endpoint]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 10;
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"https://music.youtube.com" forHTTPHeaderField:@"Origin"];
    [req setValue:IVLYTUserAgent(client) forHTTPHeaderField:@"User-Agent"];
    // a plain session: the shared lyrics session sends its own User-Agent
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        completion(IVLYTDict(json));
    }] resume];
}

/// When only the system now-playing info is known: search songs and verify the title.
- (void)youtubeVideoIDForTrack:(IVLTrack *)track completion:(void (^)(NSString *_Nullable vid))completion {
    if (track.youtubeVideoID.length) { completion(track.youtubeVideoID); return; }
    NSString *title = [IVLLyricsService cleanTitle:track.title];
    NSString *query = [NSString stringWithFormat:@"%@ %@", title, [IVLLyricsService cleanArtist:track.artist]];
    // params = "Songs" filter
    [self innerTube:@"search" client:@"WEB_REMIX" body:@{ @"query": query, @"params": @"EgWKAQIIAWoKEAkQBRAKEAMQBA==" } completion:^(NSDictionary *json) {
        NSString *want = IVLYTNorm(title);
        NSArray *shelfItems = IVLYTArray(IVLYTFind(IVLYTFind(json, @"musicShelfRenderer", 0), @"contents", 0));
        for (id item in shelfItems) {
            NSDictionary *r = IVLYTDict(IVLYTDict(item)[@"musicResponsiveListItemRenderer"]);
            if (!r) continue;
            NSString *vid = IVLYTString(IVLYTFind(r, @"videoId", 0));
            NSArray *runs = IVLYTArray(IVLYTFind(IVLYTArray(r[@"flexColumns"]).firstObject, @"runs", 0));
            NSString *name = IVLYTNorm(IVLYTString(IVLYTDict(runs.firstObject)[@"text"]));
            if (vid.length && want.length && name.length && ([name containsString:want] || [want containsString:name])) {
                completion(vid);
                return;
            }
        }
        completion(nil);
    }];
}

+ (IVLLyrics *)parseTimedYouTube:(NSArray *)timed durationMs:(NSInteger)durMs {
    NSMutableArray<IVLLyricLine *> *lines = [NSMutableArray array];
    for (id raw in timed) {
        NSDictionary *d = IVLYTDict(raw);
        NSDictionary *cue = IVLYTDict(d[@"cueRange"]);
        if (!d || !cue) continue;
        NSString *text = [IVLYTString(d[@"lyricLine"]) ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([text isEqualToString:@"♪"] || [text isEqualToString:@"♫"]) text = @"";   // instrumental marker -> gap
        IVLLyricLine *l = [IVLLyricLine new];
        l.startMs = MAX(0, [cue[@"startTimeMilliseconds"] integerValue]);
        l.endMs = MAX(0, [cue[@"endTimeMilliseconds"] integerValue]);
        l.text = text;
        [lines addObject:l];
    }
    return [IVLLyricsParser lyricsWithTimedLines:lines durationMs:durMs explicitEnds:YES];
}

- (void)youtubeLyricsForBrowseID:(NSString *)browseID clients:(NSArray<NSString *> *)clients durationMs:(NSInteger)durMs completion:(IVLLyricsCompletion)done {
    if (!clients.count) { done(nil, nil); return; }
    NSString *client = clients.firstObject;
    [self innerTube:@"browse" client:client body:@{ @"browseId": browseID } completion:^(NSDictionary *json) {
        NSArray *timed = IVLYTArray(IVLYTFind(json, @"timedLyricsData", 0));
        IVLLyrics *ly = timed.count ? [IVLLyricsService parseTimedYouTube:timed durationMs:durMs] : nil;
        if (!ly) {
            // plain text (web client / songs without timing)
            NSDictionary *shelf = IVLYTDict(IVLYTFind(json, @"musicDescriptionShelfRenderer", 0));
            NSArray *runs = IVLYTArray(IVLYTFind(shelf[@"description"], @"runs", 0));
            NSMutableString *text = [NSMutableString string];
            for (id r in runs) [text appendString:IVLYTString(IVLYTDict(r)[@"text"]) ?: @""];
            if (text.length && [clients count] == 1) ly = [IVLLyricsParser parsePlain:text];
        }
        if (ly) { ly.source = @"YouTube Music"; done(ly, nil); return; }
        [self youtubeLyricsForBrowseID:browseID clients:[clients subarrayWithRange:NSMakeRange(1, clients.count - 1)] durationMs:durMs completion:done];
    }];
}

- (void)youtubeForTrack:(IVLTrack *)track completion:(IVLLyricsCompletion)done {
    NSInteger durMs = (NSInteger)(track.duration * 1000);
    [self youtubeVideoIDForTrack:track completion:^(NSString *vid) {
        if (!vid.length) { done(nil, nil); return; }
        [self innerTube:@"next" client:@"WEB_REMIX" body:@{ @"videoId": vid, @"isAudioOnly": @YES } completion:^(NSDictionary *json) {
            NSString *browseID = IVLYTFindPrefix(json, @"MPLYt", 0);
            if (!browseID.length) { done(nil, nil); return; }
            // mobile clients first (timed lines), web last (plain text fallback)
            [self youtubeLyricsForBrowseID:browseID clients:@[@"ANDROID_MUSIC", @"IOS_MUSIC", @"WEB_REMIX"] durationMs:durMs completion:done];
        }];
    }];
}

@end
