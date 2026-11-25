// "Video captions" provider: subtitles of the music video used as time-synced lyrics.
//  1. caption tracks of the video that is playing, read from the app's own player response
//     (their URLs are already signed for this app session)
//  2. when the audio-only "song" is playing: the music video counterpart (InnerTube next ->
//     player), accepted only when its length matches the song so the timing lines up.

#import "IVLLyricsService+Private.h"
#import "IVLLyricsParser.h"
#import "IVLPlaybackManager.h"
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

/// Manual subtitles only (auto-generated ones are useless for songs); prefer the lyrics' language.
static NSDictionary *IVLPickCaptionTrack(NSArray<NSDictionary *> *tracks) {
    NSMutableArray *manual = [NSMutableArray array];
    for (NSDictionary *t in tracks) if (![t[@"asr"] boolValue]) [manual addObject:t];
    if (!manual.count) return nil;
    NSString *ui = [[NSLocale preferredLanguages].firstObject componentsSeparatedByString:@"-"].firstObject ?: @"";
    // Original-language tracks usually come first; a track in the UI language is a translation, so keep it last.
    for (NSDictionary *t in manual) if (![t[@"lang"] hasPrefix:ui]) return t;
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
        l.startMs = [e[@"tStartMs"] integerValue];
        l.endMs = l.startMs + [e[@"dDurationMs"] integerValue];
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

- (void)captionsForTrack:(IVLTrack *)track completion:(IVLLyricsCompletion)done {
    NSInteger durMs = (NSInteger)(track.duration * 1000);
    __block NSArray *inApp = nil;
    void (^readApp)(void) = ^{ inApp = [[IVLPlaybackManager shared] currentCaptionTracks]; };
    if (NSThread.isMainThread) readApp(); else dispatch_sync(dispatch_get_main_queue(), readApp);

    NSDictionary *pick = IVLPickCaptionTrack(inApp ?: @[]);
    if (pick) { [self fetchCaptionTrack:pick durationMs:durMs label:@"字幕" completion:done]; return; }

    NSString *vid = track.youtubeVideoID;
    if (!vid.length) {
        done(nil, [NSError errorWithDomain:@"IVLCaptions" code:404 userInfo:@{ NSLocalizedDescriptionKey: @"この動画に字幕はありません" }]);
        return;
    }
    // song playing: look for the music video version
    [self musicVideoCounterpartFor:vid completion:^(NSString *mv) {
        if (!mv.length) {
            done(nil, [NSError errorWithDomain:@"IVLCaptions" code:404 userInfo:@{ NSLocalizedDescriptionKey: @"字幕付きの動画版が見つかりません" }]);
            return;
        }
        [self innerTubePlayer:mv completion:^(NSDictionary *player) {
            double len = [player[@"videoDetails"][@"lengthSeconds"] doubleValue];
            if (track.duration > 0 && len > 0 && fabs(len - track.duration) > 2.0) {
                done(nil, [NSError errorWithDomain:@"IVLCaptions" code:404 userInfo:@{ NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"動画版の長さが曲と違うため使えません（%.0f秒 / %.0f秒）", len, track.duration] }]);
                return;
            }
            NSDictionary *t = IVLPickCaptionTrack(IVLCaptionTracksFromJSON(player));
            if (!t) {
                done(nil, [NSError errorWithDomain:@"IVLCaptions" code:404 userInfo:@{ NSLocalizedDescriptionKey: @"動画版に字幕がありません" }]);
                return;
            }
            [self fetchCaptionTrack:t durationMs:durMs label:@"動画字幕" completion:done];
        }];
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

- (NSArray<NSDictionary *> *)currentCaptionTracks {
    id player = self.player;
    NSString *vid = self.track.youtubeVideoID;
    NSString *playing = IVLCapStr(IVLCapFirst(player, @[@"currentVideoID", @"contentVideoID"]));
    if (!vid.length || ![vid isEqualToString:playing]) return @[];   // only the video that is actually loaded
    id response = IVLCapGet(player, @"playerResponse");
    id data = IVLCapFirst(response, @[@"playerData"]) ?: response;
    return IVLCaptionTracksFromResponse(data);
}

@end
