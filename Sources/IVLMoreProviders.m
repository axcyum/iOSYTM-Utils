// Additional lyrics providers: SpicyLyrics (word/line synced via Spotify session),
// PetitLyrics (character/word-synced WSY XML & plain text), and Genius (public search + HTML parser).

#import "IVLLyricsService+Private.h"
#import "IVLLyricsParser.h"
#import "IVLSpotify.h"

static NSString *IVLMPString(id v) { return [v isKindOfClass:[NSString class]] ? v : nil; }
static NSDictionary *IVLMPDict(id v) { return [v isKindOfClass:[NSDictionary class]] ? v : nil; }
static NSArray *IVLMPArray(id v) { return [v isKindOfClass:[NSArray class]] ? v : nil; }
static double IVLMPDouble(id v) { return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0.0; }

static NSString *IVLMPDecodeHTML(NSString *s) {
    if (!s.length) return @"";
    if (![s containsString:@"&"]) return s;
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"&(?:#([0-9]+)|#[xX]([0-9a-fA-F]+)|([a-zA-Z]+));" options:0 error:nil];
    });
    NSDictionary *named = @{ @"amp": @"&", @"apos": @"'", @"gt": @">", @"lt": @"<", @"quot": @"\"", @"nbsp": @" " };
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
            if (cp > 0 && cp <= 0x10FFFF) {
                uint32_t u = (uint32_t)cp;
                rep = [[NSString alloc] initWithBytes:&u length:4 encoding:NSUTF32LittleEndianStringEncoding];
            }
        }
        [out appendString:rep ?: [s substringWithRange:m.range]];
        last = NSMaxRange(m.range);
    }];
    [out appendString:[s substringFromIndex:last]];
    return out;
}

#pragma mark - PetitLyrics WSY XML Parser

@interface IVLPetitWSYParser : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) NSMutableArray<IVLLyricLine *> *lines;
@end

@implementation IVLPetitWSYParser {
    IVLLyricLine *_curLine;
    NSMutableArray<IVLWord *> *_curWords;
    NSInteger _wStart, _wEnd;
    NSMutableString *_buf;
    NSString *_wText;
    BOOL _inWord;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lines = [NSMutableArray array];
        _buf = [NSMutableString string];
    }
    return self;
}

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)el namespaceURI:(NSString *)ns qualifiedName:(NSString *)q attributes:(NSDictionary *)attr {
    [_buf setString:@""];
    if ([el isEqualToString:@"line"]) {
        _curLine = [IVLLyricLine new];
        _curWords = [NSMutableArray array];
    } else if ([el isEqualToString:@"word"]) {
        _inWord = YES;
        _wStart = -1;
        _wEnd = -1;
        _wText = @"";
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    [_buf appendString:string];
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)el namespaceURI:(NSString *)ns qualifiedName:(NSString *)q {
    NSString *val = [_buf copy];
    if ([el isEqualToString:@"linestring"] && _curLine) {
        _curLine.text = [val stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    } else if (_inWord) {
        if ([el isEqualToString:@"starttime"]) _wStart = val.integerValue;
        else if ([el isEqualToString:@"endtime"]) _wEnd = val.integerValue;
        else if ([el isEqualToString:@"wordstring"]) _wText = val;
        else if ([el isEqualToString:@"word"]) {
            _inWord = NO;
            if (_wStart >= 0 && _wText.length) {
                IVLWord *w = [IVLWord new];
                w.startMs = _wStart;
                w.endMs = (_wEnd > _wStart) ? _wEnd : (_wStart + 250);
                w.text = _wText;
                [_curWords addObject:w];
            }
        }
    } else if ([el isEqualToString:@"line"] && _curLine) {
        if (_curWords.count) {
            _curLine.startMs = _curWords.firstObject.startMs;
            _curLine.endMs = _curWords.lastObject.endMs;
            _curLine.words = [_curWords copy];
            if (!_curLine.text.length) {
                NSMutableString *joined = [NSMutableString string];
                for (IVLWord *w in _curWords) [joined appendString:w.text ?: @""];
                _curLine.text = joined;
            }
            if (_curLine.text.length) [_lines addObject:_curLine];
        }
        _curLine = nil;
        _curWords = nil;
    }
}

@end

static NSString *IVLExtractXMLTag(NSString *xml, NSString *tag) {
    if (!xml.length) return nil;
    NSString *open = [NSString stringWithFormat:@"<%@>", tag];
    NSString *close = [NSString stringWithFormat:@"</%@>", tag];
    NSRange r1 = [xml rangeOfString:open];
    if (r1.location == NSNotFound) return nil;
    NSUInteger start = NSMaxRange(r1);
    NSRange r2 = [xml rangeOfString:close options:0 range:NSMakeRange(start, xml.length - start)];
    if (r2.location == NSNotFound) return nil;
    return [xml substringWithRange:NSMakeRange(start, r2.location - start)];
}

@implementation IVLLyricsService (MoreProviders)

#pragma mark - 1. PetitLyrics

- (void)petitLyricsQuery:(NSString *)title artist:(NSString *)artist type:(NSInteger)ltype durationMs:(NSInteger)durMs completion:(IVLLyricsCompletion)done {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"];
    NSString *encTitle = [title stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
    NSString *encArtist = [artist stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
    NSString *form = [NSString stringWithFormat:@"clientAppId=p1110417&key_title=%@&key_artist=%@&lyricsType=%ld&terminalType=10",
                      encTitle, encArtist, (long)ltype];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://p1.petitlyrics.com/api/GetPetitLyricsData.php"]];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 10.0;
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"Mozilla/5.0" forHTTPHeaderField:@"User-Agent"];
    req.HTTPBody = [form dataUsingEncoding:NSUTF8StringEncoding];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSString *xml = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSString *b64 = IVLExtractXMLTag(xml, @"lyricsData");
        NSString *gotType = IVLExtractXMLTag(xml, @"lyricsType");
        if (!b64.length) { done(nil, err); return; }

        NSData *raw = [[NSData alloc] initWithBase64EncodedString:b64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (!raw.length) { done(nil, nil); return; }

        IVLLyrics *ly = nil;
        if ([gotType isEqualToString:@"3"]) {
            IVLPetitWSYParser *p = [IVLPetitWSYParser new];
            NSXMLParser *xp = [[NSXMLParser alloc] initWithData:raw];
            xp.delegate = p;
            [xp parse];
            if (p.lines.count) {
                ly = [IVLLyricsParser lyricsWithTimedLines:p.lines durationMs:durMs explicitEnds:YES];
                ly.karaoke = YES;
            }
        }
        if (!ly) {
            NSString *txt = [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding];
            if (txt.length && ![txt hasPrefix:@"MHDROBJT"]) {
                ly = [IVLLyricsParser parsePlain:txt];
            }
        }
        if (ly) ly.source = @"PetitLyrics";
        done(ly, nil);
    }] resume];
}

- (void)petitLyricsForTrack:(IVLTrack *)track completion:(IVLLyricsCompletion)done {
    NSString *title = [IVLLyricsService cleanTitle:track.title];
    NSString *artist = [IVLLyricsService artistCandidates:track.artist].firstObject ?: [IVLLyricsService cleanArtist:track.artist];
    if (!title.length) { done(nil, nil); return; }
    NSInteger durMs = (NSInteger)(track.duration * 1000);

    // Try word/character-synced WSY (type 3) first; fall back to plain text (type 1)
    [self petitLyricsQuery:title artist:artist type:3 durationMs:durMs completion:^(IVLLyrics *ly, NSError *err) {
        if (ly.lines.count) { done(ly, nil); return; }
        [self petitLyricsQuery:title artist:artist type:1 durationMs:durMs completion:^(IVLLyrics *ly2, NSError *err2) {
            done(ly2, ly2 ? nil : (err2 ?: err));
        }];
    }];
}

#pragma mark - 2. Genius

- (void)geniusForTrack:(IVLTrack *)track completion:(IVLLyricsCompletion)done {
    NSString *title = [IVLLyricsService cleanTitle:track.title];
    NSString *artist = [IVLLyricsService artistCandidates:track.artist].firstObject ?: [IVLLyricsService cleanArtist:track.artist];
    if (!title.length) { done(nil, nil); return; }
    NSString *q = artist.length ? [NSString stringWithFormat:@"%@ %@", title, artist] : title;

    NSURL *searchURL = [IVLLyricsService URLWithBase:@"https://genius.com" path:@"/api/search/multi" query:@{ @"q": q }];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:searchURL];
    req.timeoutInterval = 10.0;
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15" forHTTPHeaderField:@"User-Agent"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSArray *sections = IVLMPArray(IVLMPDict(IVLMPDict(json)[@"response"])[@"sections"]);
        NSMutableArray<NSDictionary *> *cands = [NSMutableArray array];
        NSString *fallbackURL = nil;

        for (id s in sections) {
            NSDictionary *sd = IVLMPDict(s);
            if (![sd[@"type"] isEqualToString:@"song"]) continue;
            for (id h in IVLMPArray(sd[@"hits"])) {
                NSDictionary *res = IVLMPDict(IVLMPDict(h)[@"result"]);
                NSString *url = IVLMPString(res[@"url"]);
                NSString *rTitle = IVLMPString(res[@"title"]) ?: @"";
                NSString *rArtist = IVLMPString(res[@"artist_names"]) ?: @"";
                if (!url.length) continue;
                if (!fallbackURL) fallbackURL = url;
                // Avoid Genius Romanizations / Translations pages unless no original exists
                NSString *la = rArtist.lowercaseString;
                if ([la containsString:@"genius romanization"] || [la containsString:@"genius english translation"]) continue;
                [cands addObject:@{ @"id": url, @"title": rTitle, @"artist": rArtist, @"duration": @0 }];
            }
        }
        NSDictionary *best = cands.count ? IVLBestCandidate(cands, track) : nil;
        NSString *pageURL = IVLMPString(best[@"id"]) ?: fallbackURL;
        if (!pageURL.length) { done(nil, err); return; }

        NSMutableURLRequest *preq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:pageURL]];
        preq.timeoutInterval = 12.0;
        [preq setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15" forHTTPHeaderField:@"User-Agent"];

        [[[NSURLSession sharedSession] dataTaskWithRequest:preq completionHandler:^(NSData *hdata, NSURLResponse *hresp, NSError *herr) {
            NSString *html = hdata.length ? [[NSString alloc] initWithData:hdata encoding:NSUTF8StringEncoding] : nil;
            if (!html.length) { done(nil, herr); return; }

            static NSRegularExpression *blockRe, *brRe, *tagRe;
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                blockRe = [NSRegularExpression regularExpressionWithPattern:@"data-lyrics-container=\"true\"[^>]*>(.*?)</div>" options:NSRegularExpressionDotMatchesLineSeparators error:nil];
                brRe = [NSRegularExpression regularExpressionWithPattern:@"<br\\s*/?>" options:NSRegularExpressionCaseInsensitive error:nil];
                tagRe = [NSRegularExpression regularExpressionWithPattern:@"<[^>]+>" options:0 error:nil];
            });

            NSMutableArray<NSString *> *parts = [NSMutableArray array];
            NSArray<NSTextCheckingResult *> *matches = [blockRe matchesInString:html options:0 range:NSMakeRange(0, html.length)];
            for (NSTextCheckingResult *m in matches) {
                if (m.numberOfRanges < 2) continue;
                NSString *chunk = [html substringWithRange:[m rangeAtIndex:1]];
                chunk = [brRe stringByReplacingMatchesInString:chunk options:0 range:NSMakeRange(0, chunk.length) withTemplate:@"\n"];
                chunk = [tagRe stringByReplacingMatchesInString:chunk options:0 range:NSMakeRange(0, chunk.length) withTemplate:@""];
                chunk = IVLMPDecodeHTML(chunk);
                chunk = [chunk stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (chunk.length) [parts addObject:chunk];
            }
            NSString *full = [parts componentsJoinedByString:@"\n"];
            IVLLyrics *ly = full.length ? [IVLLyricsParser parsePlain:full] : nil;
            if (ly) ly.source = @"Genius";
            done(ly, nil);
        }] resume];
    }] resume];
}

#pragma mark - 3. SpicyLyrics

- (IVLLyrics *)parseSpicyLyricsData:(NSDictionary *)data durationMs:(NSInteger)durMs {
    if (!data) return nil;
    NSString *type = IVLMPString(data[@"Type"]) ?: @"";
    NSMutableArray<IVLLyricLine *> *lines = [NSMutableArray array];
    BOOL hasKaraoke = NO;

    if ([type isEqualToString:@"Syllable"]) {
        for (id item in IVLMPArray(data[@"Content"])) {
            NSDictionary *cd = IVLMPDict(item);
            if (![cd[@"Type"] isEqualToString:@"Vocal"]) continue;
            NSDictionary *lead = IVLMPDict(cd[@"Lead"]);
            NSArray *syls = IVLMPArray(lead[@"Syllables"]);
            if (!syls.count) continue;

            IVLLyricLine *line = [IVLLyricLine new];
            line.alternateVoice = [cd[@"OppositeAligned"] respondsToSelector:@selector(boolValue)] && [cd[@"OppositeAligned"] boolValue];
            NSMutableArray<IVLWord *> *words = [NSMutableArray array];
            NSMutableString *text = [NSMutableString string];
            for (id s in syls) {
                NSDictionary *sd = IVLMPDict(s);
                NSString *t = IVLMPString(sd[@"Text"]) ?: @"";
                if (!t.length) continue;
                BOOL isPart = [sd[@"IsPartOfWord"] respondsToSelector:@selector(boolValue)] && [sd[@"IsPartOfWord"] boolValue];
                NSString *wText = isPart ? t : [t stringByAppendingString:@" "];
                IVLWord *w = [IVLWord new];
                w.startMs = (NSInteger)llround(IVLMPDouble(sd[@"StartTime"]) * 1000.0);
                w.endMs = (NSInteger)llround(IVLMPDouble(sd[@"EndTime"]) * 1000.0);
                if (w.endMs <= w.startMs) w.endMs = w.startMs + 200;
                w.text = wText;
                [words addObject:w];
                [text appendString:wText];
            }
            if (!words.count) continue;
            line.startMs = (NSInteger)llround(IVLMPDouble(lead[@"StartTime"]) * 1000.0);
            if (line.startMs <= 0) line.startMs = words.firstObject.startMs;
            line.endMs = (NSInteger)llround(IVLMPDouble(lead[@"EndTime"]) * 1000.0);
            if (line.endMs <= line.startMs) line.endMs = words.lastObject.endMs;
            line.text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            line.words = words;
            hasKaraoke = YES;
            if (line.text.length) [lines addObject:line];
        }
    } else if ([type isEqualToString:@"Line"]) {
        for (id item in IVLMPArray(data[@"Content"])) {
            NSDictionary *cd = IVLMPDict(item);
            NSString *t = IVLMPString(cd[@"Text"]);
            if (!t.length) continue;
            IVLLyricLine *line = [IVLLyricLine new];
            line.startMs = (NSInteger)llround(IVLMPDouble(cd[@"StartTime"]) * 1000.0);
            line.endMs = (NSInteger)llround(IVLMPDouble(cd[@"EndTime"]) * 1000.0);
            line.text = t;
            line.alternateVoice = [cd[@"OppositeAligned"] respondsToSelector:@selector(boolValue)] && [cd[@"OppositeAligned"] boolValue];
            [lines addObject:line];
        }
    } else if ([type isEqualToString:@"Static"]) {
        NSMutableArray<NSString *> *plain = [NSMutableArray array];
        for (id item in IVLMPArray(data[@"Lines"])) {
            NSString *t = IVLMPString(IVLMPDict(item)[@"Text"]);
            if (t.length) [plain addObject:t];
        }
        if (plain.count) {
            IVLLyrics *ly = [IVLLyricsParser parsePlain:[plain componentsJoinedByString:@"\n"]];
            ly.source = @"SpicyLyrics";
            return ly;
        }
    }

    if (!lines.count) return nil;
    IVLLyrics *ly = [IVLLyricsParser lyricsWithTimedLines:lines durationMs:durMs explicitEnds:YES];
    ly.karaoke = hasKaraoke;
    ly.source = @"SpicyLyrics";
    return ly;
}

- (void)spicyLyricsForTrack:(IVLTrack *)track completion:(IVLLyricsCompletion)done {
    NSInteger durMs = (NSInteger)(track.duration * 1000);
    [[IVLSpotify shared] resolveTokenAndTrackIDForTrack:track completion:^(NSString *token, NSString *trackID, NSError *err) {
        if (!token.length || !trackID.length) { done(nil, err); return; }

        NSDictionary *payload = @{
            @"queries": @[@{
                @"operation": @"lyrics",
                @"variables": @{ @"id": trackID, @"auth": @"SpicyLyrics-WebAuth" },
            }],
            @"client": @{ @"version": @"5.22.0" },
        };
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://api.spicylyrics.org/query"]];
        req.HTTPMethod = @"POST";
        req.timeoutInterval = 10.0;
        [req setValue:@"2" forHTTPHeaderField:@"X-mode"];
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [req setValue:@"5.22.0" forHTTPHeaderField:@"SpicyLyrics-Version"];
        [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"SpicyLyrics-WebAuth"];
        [req setValue:@"Mozilla/5.0" forHTTPHeaderField:@"User-Agent"];
        req.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

        [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *netErr) {
            id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSArray *qs = IVLMPArray(IVLMPDict(json)[@"queries"]);
            NSDictionary *res = IVLMPDict(IVLMPDict(qs.firstObject)[@"result"]);
            NSDictionary *ld = IVLMPDict(res[@"data"]);
            IVLLyrics *ly = ld ? [self parseSpicyLyricsData:ld durationMs:durMs] : nil;
            done(ly, ly ? nil : netErr);
        }] resume];
    }];
}

@end
