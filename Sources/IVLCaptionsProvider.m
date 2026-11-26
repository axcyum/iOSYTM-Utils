// "Video captions" provider: subtitles of the music video used as time-synced lyrics.
//  1. caption tracks of the video that is playing, read from the app's own player response
//     (their URLs are already signed for this app session)
//  2. when the audio-only "song" is playing: the music video counterpart (InnerTube next ->
//     player), accepted only when its length matches the song so the timing lines up.

#import "IVLLyricsService+Private.h"
#import "IVLLyricsParser.h"
#import "IVLPlaybackManager.h"
#import "IVLSettings.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <string.h>

static NSString *IVLCapStr(id v) { return [v isKindOfClass:[NSString class]] ? v : nil; }

/// Calls a no-argument, object-returning getter if the object has one (protobuf models change names).
static id IVLCapGet(id obj, NSString *name) {
    if (!obj) return nil;
    SEL sel = NSSelectorFromString(name);
    if (![obj respondsToSelector:sel]) return nil;
    NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
    if (sig.numberOfArguments != 2) return nil;
    const char *t = sig.methodReturnType;
    while (*t && strchr("rnNoORV", *t)) t++;
    if (*t != '@') return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(obj, sel); } @catch (__unused NSException *e) { return nil; }
}

static id IVLCapFirst(id obj, NSArray<NSString *> *names) {
    for (NSString *n in names) { id v = IVLCapGet(obj, n); if (v) return v; }
    return nil;
}

static NSString *IVLCapText(id formatted) {
    if ([formatted isKindOfClass:[NSString class]]) return formatted;
    NSString *s = IVLCapStr(IVLCapFirst(formatted, @[@"simpleText", @"text", @"accessibilityLabel"]));
    if (s.length) return s;
    NSArray *runs = IVLCapFirst(formatted, @[@"runsArray", @"runs"]);
    NSMutableString *m = [NSMutableString string];
    for (id r in [runs isKindOfClass:[NSArray class]] ? runs : @[]) [m appendString:IVLCapStr(IVLCapGet(r, @"text")) ?: @""];
    return m;
}

/// [{url, lang, name, asr}] from a YTIPlayerResponse-like object.
static NSArray<NSDictionary *> *IVLCaptionTracksFromResponse(id data) {
    id captions = IVLCapFirst(data, @[@"captions"]);
    id list = IVLCapFirst(captions, @[@"playerCaptionsTracklistRenderer"]);
    NSArray *tracks = IVLCapFirst(list, @[@"captionTracksArray", @"captionTracks"]);
    NSMutableArray *out = [NSMutableArray array];
    for (id t in [tracks isKindOfClass:[NSArray class]] ? tracks : @[]) {
        NSString *url = IVLCapStr(IVLCapFirst(t, @[@"baseURL", @"baseUrl", @"URL", @"url"]));
        if (!url.length) continue;
        NSString *kind = IVLCapStr(IVLCapGet(t, @"kind")) ?: @"";
        NSString *vss = IVLCapStr(IVLCapGet(t, @"vssId")) ?: @"";
        [out addObject:@{ @"url": url, @"lang": IVLCapStr(IVLCapGet(t, @"languageCode")) ?: @"",
                          @"name": IVLCapText(IVLCapGet(t, @"name")) ?: @"",
                          @"asr": @([kind isEqualToString:@"asr"] || [vss hasPrefix:@"a."]) }];
    }
    return out;
}

/// Same, from InnerTube JSON.
static NSArray<NSDictionary *> *IVLCaptionTracksFromJSON(NSDictionary *player) {
    NSArray *tracks = player[@"captions"][@"playerCaptionsTracklistRenderer"][@"captionTracks"];
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *t in [tracks isKindOfClass:[NSArray class]] ? tracks : @[]) {
        if (![t isKindOfClass:[NSDictionary class]] || !IVLCapStr(t[@"baseUrl"]).length) continue;
        NSDictionary *name = [t[@"name"] isKindOfClass:[NSDictionary class]] ? t[@"name"] : nil;
        NSString *n = IVLCapStr(name[@"simpleText"]) ?: IVLCapStr([name[@"runs"] firstObject][@"text"]) ?: @"";
        [out addObject:@{ @"url": t[@"baseUrl"], @"lang": IVLCapStr(t[@"languageCode"]) ?: @"", @"name": n,
                          @"asr": @([t[@"kind"] isEqual:@"asr"]) }];
    }
    return out;
}

/// Language the song is most likely sung in, from the title/artist script.
static NSString *IVLGuessSongLanguage(IVLTrack *track) {
    NSString *s = [NSString stringWithFormat:@"%@ %@", track.title ?: @"", track.artist ?: @""];
    if ([s rangeOfString:@"[\\u3040-\\u30ff]" options:NSRegularExpressionSearch].location != NSNotFound) return @"ja";
    if ([s rangeOfString:@"[\\uac00-\\ud7af]" options:NSRegularExpressionSearch].location != NSNotFound) return @"ko";
    if ([s rangeOfString:@"[\\u4e00-\\u9fff]" options:NSRegularExpressionSearch].location != NSNotFound) return @"ja";   // kanji-only titles are mostly Japanese here
    return nil;
}

static BOOL IVLLangMatches(NSString *trackLang, NSString *want) {
    if (!want.length || !trackLang.length) return NO;
    NSString *a = trackLang.lowercaseString, *b = want.lowercaseString;
    if ([a isEqualToString:b]) return YES;
    // "zh-Hant"/"zh-TW", "zh-Hans"/"zh-CN": only match the same script family
    if ([b hasPrefix:@"zh"]) {
        BOOL wantT = [b containsString:@"tw"] || [b containsString:@"hant"] || [b containsString:@"hk"];
        BOOL isT = [a containsString:@"tw"] || [a containsString:@"hant"] || [a containsString:@"hk"];
        return [a hasPrefix:@"zh"] && wantT == isT;
    }
    return [[a componentsSeparatedByString:@"-"].firstObject isEqualToString:[b componentsSeparatedByString:@"-"].firstObject];
}

/// Manual subtitles only (auto-generated ones are useless for songs).
/// Order: language chosen in settings > language of the song > device language > first manual track.
NSDictionary *IVLPickCaptionTrack(NSArray<NSDictionary *> *tracks, IVLTrack *track) {
    NSMutableArray *manual = [NSMutableArray array];
    for (NSDictionary *t in tracks) if (![t[@"asr"] boolValue]) [manual addObject:t];
    if (!manual.count) return nil;
    NSString *pref = [IVLSettings objectForKey:IVLKeyCaptionLang];
    NSString *ui = [[NSLocale preferredLanguages].firstObject componentsSeparatedByString:@"-"].firstObject;
    NSMutableArray *order = [NSMutableArray array];
    if ([pref isKindOfClass:[NSString class]] && pref.length) [order addObject:pref];
    NSString *song = IVLGuessSongLanguage(track);
    if (song) [order addObject:song];
    if (ui) [order addObject:ui];
    for (NSString *want in order) {
        for (NSDictionary *t in manual) if (IVLLangMatches(t[@"lang"], want)) return t;
    }
    return manual.firstObject;
}

static IVLLyrics *IVLParseJSON3(NSDictionary *json, NSInteger durMs) {
    NSArray *events = [json isKindOfClass:[NSDictionary class]] ? json[@"events"] : nil;
    NSMutableArray<IVLLyricLine *> *lines = [NSMutableArray array];
    for (NSDictionary *e in [events isKindOfClass:[NSArray class]] ? events : @[]) {
        NSArray *segs = [e isKindOfClass:[NSDictionary class]] ? e[@"segs"] : nil;
        if (![segs isKindOfClass:[NSArray class]] || [e[@"aAppend"] boolValue]) continue;
        NSMutableString *text = [NSMutableString string];
        for (NSDictionary *sg in segs) [text appendString:IVLCapStr([sg isKindOfClass:[NSDictionary class]] ? sg[@"utf8"] : nil) ?: @""];
        NSString *t = [[text stringByReplacingOccurrencesOfString:@"\n" withString:@" "] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        // "♪ lyric ♪" decorations; a bare note marks an instrumental part
        t = [[t stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"♪♫♬ 　"]] copy];
        IVLLyricLine *l = [IVLLyricLine new];
        id tsObj = e[@"tStartMs"], durObj = e[@"dDurationMs"];
        l.startMs = [tsObj respondsToSelector:@selector(integerValue)] ? [tsObj integerValue] : 0;
        l.endMs = l.startMs + ([durObj respondsToSelector:@selector(integerValue)] ? [durObj integerValue] : 0);
        l.text = t;
        [lines addObject:l];
    }
    return [IVLLyricsParser lyricsWithTimedLines:lines durationMs:durMs explicitEnds:YES];
}

@implementation IVLLyricsService (Captions)

- (void)fetchCaptionTrack:(NSDictionary *)track durationMs:(NSInteger)durMs label:(NSString *)label completion:(IVLLyricsCompletion)done {
    NSString *url = track[@"url"];
    url = [url containsString:@"fmt="] ? url : [url stringByAppendingString:@"&fmt=json3"];
    [self getJSON:[NSURL URLWithString:url] completion:^(id json, NSInteger status, NSError *error) {
        IVLLyrics *ly = status == 200 ? IVLParseJSON3(json, durMs) : nil;
        if (ly) {
            ly.source = [NSString stringWithFormat:@"%@ (%@)", label, [track[@"name"] length] ? track[@"name"] : track[@"lang"]];
            done(ly, nil);
            return;
        }
        done(nil, [NSError errorWithDomain:@"IVLCaptions" code:(status == 200 ? 404 : (status ?: 503))
                                  userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"captions HTTP %ld", (long)status] }]);
    }];
}

static NSError *IVLCapError(NSString *message) {
    return [NSError errorWithDomain:@"IVLCaptions" code:404 userInfo:@{ NSLocalizedDescriptionKey: message }];
}

/// Finds the caption tracks to use for `track`: the playing video (app, then player API),
/// then the music video version of an audio-only song (same length only).
- (void)captionTrackListForTrack:(IVLTrack *)track completion:(void (^)(NSArray<NSDictionary *> *tracks, NSString *label, NSString *failure))completion {
    __block NSArray *inApp = nil;
    __block NSString *playing = nil;
    void (^readApp)(void) = ^{
        IVLPlaybackManager *m = [IVLPlaybackManager shared];
        playing = [m captionVideoIDForTrack:track];
        inApp = playing ? [m currentCaptionTracks] : @[];
    };
    if (NSThread.isMainThread) readApp(); else dispatch_sync(dispatch_get_main_queue(), readApp);
    NSString *vid = playing ?: track.youtubeVideoID;

    if (IVLPickCaptionTrack(inApp ?: @[], track)) { completion(inApp, @"字幕", nil); return; }
    if (!vid.length) { completion(@[], nil, @"再生中の動画を特定できません"); return; }
    NSString *appNote = [NSString stringWithFormat:@"アプリ内 %lu件", (unsigned long)inApp.count];
    [self innerTubePlayer:vid completion:^(NSDictionary *player) {
        NSArray *tracks = IVLCaptionTracksFromJSON(player ?: @{});
        if (IVLPickCaptionTrack(tracks, track)) { completion(tracks, @"字幕", nil); return; }
        NSString *status = [player[@"playabilityStatus"][@"status"] description] ?: (player ? @"?" : @"通信失敗");
        NSString *apiNote = [NSString stringWithFormat:@"API %@ %lu件", status, (unsigned long)tracks.count];
        [self musicVideoCounterpartFor:vid completion:^(NSString *mv) {
            if (!mv.length) { completion(@[], nil, [NSString stringWithFormat:@"字幕なし（%@ / %@ / 動画版なし）", appNote, apiNote]); return; }
            [self innerTubePlayer:mv completion:^(NSDictionary *mp) {
                NSDictionary *vd = [mp[@"videoDetails"] isKindOfClass:[NSDictionary class]] ? mp[@"videoDetails"] : nil;
                id lenObj = vd[@"lengthSeconds"];
                double len = [lenObj respondsToSelector:@selector(doubleValue)] ? [lenObj doubleValue] : 0.0;
                if (track.duration > 0 && len > 0 && fabs(len - track.duration) > 2.0) {
                    completion(@[], nil, [NSString stringWithFormat:@"動画版の長さが曲と違うため使えません（%.0f秒 / %.0f秒）", len, track.duration]);
                    return;
                }
                NSArray *mt = IVLCaptionTracksFromJSON(mp ?: @{});
                if (!IVLPickCaptionTrack(mt, track)) { completion(@[], nil, [NSString stringWithFormat:@"字幕なし（%@ / %@ / 動画版にも字幕なし）", appNote, apiNote]); return; }
                completion(mt, @"動画字幕", nil);
            }];
        }];
    }];
}

- (void)captionsForTrack:(IVLTrack *)track completion:(IVLLyricsCompletion)done {
    NSInteger durMs = (NSInteger)(track.duration * 1000);
    [self captionTrackListForTrack:track completion:^(NSArray *tracks, NSString *label, NSString *failure) {
        NSDictionary *pick = IVLPickCaptionTrack(tracks, track);
        if (!pick) { done(nil, IVLCapError(failure ?: @"字幕なし")); return; }
        [self fetchCaptionTrack:pick durationMs:durMs label:label completion:done];
    }];
}

- (void)musicVideoCounterpartFor:(NSString *)vid completion:(void (^)(NSString *_Nullable))completion {
    NSDictionary *client = @{ @"client": @{ @"clientName": @"WEB_REMIX", @"clientVersion": @"1.20250310.01.00" } };
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://music.youtube.com/youtubei/v1/next?prettyPrint=false"]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{ @"context": client, @"videoId": vid } options:0 error:nil];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        NSString *body = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        // The song/video switch lives under "counterpart"; its renderer carries the video's id.
        NSRange c = [body rangeOfString:@"\"counterpart\""];
        NSString *found = nil;
        if (c.location != NSNotFound) {
            NSString *tail = [body substringFromIndex:c.location];
            NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\"videoId\"\\s*:\\s*\"([A-Za-z0-9_-]{11})\"" options:0 error:nil];
            NSTextCheckingResult *m = [re firstMatchInString:tail options:0 range:NSMakeRange(0, MIN(tail.length, 20000))];
            if (m) found = [tail substringWithRange:[m rangeAtIndex:1]];
        }
        completion([found isEqualToString:vid] ? nil : found);
    }] resume];
}

- (void)innerTubePlayer:(NSString *)vid completion:(void (^)(NSDictionary *_Nullable))completion {
    NSDictionary *client = @{ @"client": @{ @"clientName": @"IOS", @"clientVersion": @"20.10.4", @"deviceModel": @"iPhone16,2",
                                            @"osName": @"iOS", @"osVersion": @"18.5" } };
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://www.youtube.com/youtubei/v1/player?prettyPrint=false"]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_5 like Mac OS X)" forHTTPHeaderField:@"User-Agent"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{ @"context": client, @"videoId": vid } options:0 error:nil];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        completion([json isKindOfClass:[NSDictionary class]] ? json : nil);
    }] resume];
}

@end

#pragma mark - Player side

@implementation IVLPlaybackManager (Captions)

/// Video id loaded in the player when it is this track (title or length must agree).
- (NSString *)captionVideoIDForTrack:(IVLTrack *)track {
    id player = self.player;
    NSString *playing = IVLCapStr(IVLCapFirst(player, @[@"currentVideoID", @"contentVideoID"]));
    if (!playing.length) return nil;
    if ([playing isEqualToString:track.youtubeVideoID]) return playing;
    id response = IVLCapGet(player, @"playerResponse");
    id data = IVLCapFirst(response, @[@"playerData"]) ?: response;
    id details = IVLCapGet(data, @"videoDetails");
    NSString *title = IVLCapStr(IVLCapGet(details, @"title")).lowercaseString;
    NSString *want = track.title.lowercaseString;
    BOOL titleMatch = title.length && want.length && ([title containsString:want] || [want containsString:title]);
    CGFloat len = 0;
    if ([player respondsToSelector:@selector(currentVideoTotalMediaTime)]) {
        len = ((CGFloat (*)(id, SEL))objc_msgSend)(player, @selector(currentVideoTotalMediaTime));
    }
    BOOL lengthMatch = len > 0 && track.duration > 0 && fabs(len - track.duration) < 1.5;
    return (titleMatch || lengthMatch) ? playing : nil;
}

- (NSArray<NSDictionary *> *)currentCaptionTracks {
    id response = IVLCapGet(self.player, @"playerResponse");
    id data = IVLCapFirst(response, @[@"playerData"]) ?: response;
    return IVLCaptionTracksFromResponse(data);
}

@end
