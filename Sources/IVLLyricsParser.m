#import "IVLLyricsParser.h"

static const NSInteger kBreakMinGapMs = 6000;
static const NSInteger kDefaultLastLineMs = 5000;

static NSInteger IVLFractionToMs(NSString *frac) {
    if (!frac.length) return 0;
    NSInteger v = frac.integerValue;
    if (frac.length == 1) return v * 100;
    if (frac.length == 2) return v * 10;
    if (frac.length == 3) return v;
    return [[frac substringToIndex:3] integerValue];
}

static NSString *IVLCollapseWhitespace(NSString *s) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ re = [NSRegularExpression regularExpressionWithPattern:@"[\\s\\u00A0]+" options:0 error:nil]; });
    return [re stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@" "];
}

#pragma mark - Common post-processing

static IVLLyrics *IVLFinalize(NSMutableArray<IVLLyricLine *> *lines, NSInteger durationMs, BOOL hasExplicitEnds) {
    [lines sortUsingComparator:^NSComparisonResult(IVLLyricLine *a, IVLLyricLine *b) {
        if (a.startMs == b.startMs) return NSOrderedSame;
        return a.startMs < b.startMs ? NSOrderedAscending : NSOrderedDescending;
    }];

    // End times: LRC lines end where the next timed entry (including empty ones) starts.
    for (NSUInteger i = 0; i < lines.count; i++) {
        IVLLyricLine *l = lines[i];
        NSInteger next = (i + 1 < lines.count) ? lines[i + 1].startMs : NSIntegerMax;
        if (!hasExplicitEnds || l.endMs <= l.startMs) {
            NSInteger lastWordEnd = l.words.count ? l.words.lastObject.endMs : 0;
            NSInteger fallback = MAX(l.startMs + kDefaultLastLineMs, lastWordEnd);
            if (durationMs > 0 && next == NSIntegerMax) fallback = MAX(MIN(fallback, durationMs), l.startMs + 1000);
            l.endMs = (next == NSIntegerMax) ? fallback : next;
        }
    }

    // Drop empty (terminator) entries.
    NSMutableArray<IVLLyricLine *> *content = [NSMutableArray array];
    for (IVLLyricLine *l in lines) {
        if ([l.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length) [content addObject:l];
    }
    if (!content.count) return nil;

    // Word end times / clamp.
    BOOL karaoke = NO;
    for (IVLLyricLine *l in content) {
        if (!l.words.count) { l.words = nil; continue; }
        karaoke = YES;
        NSArray<IVLWord *> *ws = l.words;
        for (NSUInteger i = 0; i < ws.count; i++) {
            IVLWord *w = ws[i];
            if (w.endMs <= w.startMs) w.endMs = (i + 1 < ws.count) ? ws[i + 1].startMs : l.endMs;
            if (w.endMs <= w.startMs) w.endMs = w.startMs + 1;
        }
    }

    // Instrumental breaks (ivLyrics InstrumentalBreaks).
    NSMutableArray<IVLLyricLine *> *out = [NSMutableArray array];
    NSInteger prevEnd = 0;
    for (IVLLyricLine *l in content) {
        NSInteger gapStart = prevEnd;
        if (out.count) gapStart = MIN(prevEnd, out.lastObject.words.count ? out.lastObject.words.lastObject.endMs : prevEnd);
        if (l.startMs - gapStart >= kBreakMinGapMs) {
            IVLLyricLine *b = [IVLLyricLine new];
            b.instrumental = YES;
            b.text = @"";
            b.startMs = gapStart;
            b.endMs = l.startMs;
            if (out.count) out.lastObject.endMs = MIN(out.lastObject.endMs, gapStart);
            [out addObject:b];
        }
        [out addObject:l];
        prevEnd = l.endMs;
    }

    IVLLyrics *ly = [IVLLyrics new];
    ly.lines = out;
    ly.synced = YES;
    ly.karaoke = karaoke;
    return ly;
}

@interface IVLTTMLDelegate : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) NSMutableArray<IVLLyricLine *> *lines;
@end

@implementation IVLLyricsParser

#pragma mark - LRC

+ (IVLLyrics *)parseLRC:(NSString *)lrc durationMs:(NSInteger)durationMs {
    if (!lrc.length) return nil;
    static NSRegularExpression *timeRe, *wordRe, *offsetRe;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        timeRe = [NSRegularExpression regularExpressionWithPattern:@"^\\s*\\[(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]" options:0 error:nil];
        wordRe = [NSRegularExpression regularExpressionWithPattern:@"<(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?>" options:0 error:nil];
        offsetRe = [NSRegularExpression regularExpressionWithPattern:@"^\\s*\\[offset:\\s*([+-]?\\d+)\\s*\\]" options:NSRegularExpressionCaseInsensitive error:nil];
    });

    NSInteger offset = 0;
    NSMutableArray<IVLLyricLine *> *lines = [NSMutableArray array];
    NSString *normalized = [[lrc stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];

    for (NSString *raw in [normalized componentsSeparatedByString:@"\n"]) {
        NSTextCheckingResult *om = [offsetRe firstMatchInString:raw options:0 range:NSMakeRange(0, raw.length)];
        if (om) { offset = [[raw substringWithRange:[om rangeAtIndex:1]] integerValue]; continue; }

        NSMutableArray<NSNumber *> *times = [NSMutableArray array];
        NSString *rest = raw;
        NSTextCheckingResult *m;
        while ((m = [timeRe firstMatchInString:rest options:0 range:NSMakeRange(0, rest.length)])) {
            NSInteger min = [[rest substringWithRange:[m rangeAtIndex:1]] integerValue];
            NSInteger sec = [[rest substringWithRange:[m rangeAtIndex:2]] integerValue];
            NSRange fr = [m rangeAtIndex:3];
            NSInteger ms = fr.location == NSNotFound ? 0 : IVLFractionToMs([rest substringWithRange:fr]);
            [times addObject:@(min * 60000 + sec * 1000 + ms)];
            rest = [rest substringFromIndex:NSMaxRange(m.range)];
        }
        if (!times.count) continue;

        // Enhanced LRC word tags
        NSArray<NSTextCheckingResult *> *wm = [wordRe matchesInString:rest options:0 range:NSMakeRange(0, rest.length)];
        NSMutableArray<IVLWord *> *words = nil;
        NSString *text;
        if (wm.count) {
            words = [NSMutableArray array];
            NSString *lead = [rest substringToIndex:wm.firstObject.range.location];
            for (NSUInteger i = 0; i < wm.count; i++) {
                NSTextCheckingResult *r = wm[i];
                NSInteger t = [[rest substringWithRange:[r rangeAtIndex:1]] integerValue] * 60000
                            + [[rest substringWithRange:[r rangeAtIndex:2]] integerValue] * 1000
                            + ([r rangeAtIndex:3].location == NSNotFound ? 0 : IVLFractionToMs([rest substringWithRange:[r rangeAtIndex:3]]));
                NSUInteger from = NSMaxRange(r.range);
                NSUInteger to = (i + 1 < wm.count) ? wm[i + 1].range.location : rest.length;
                NSString *wt = [rest substringWithRange:NSMakeRange(from, to - from)];
                if (i == 0 && lead.length) wt = [lead stringByAppendingString:wt];
                if (wt.length == 0) {
                    // closing tag -> end of previous word
                    if (words.count) words.lastObject.endMs = t;
                    continue;
                }
                if (words.count && words.lastObject.endMs <= words.lastObject.startMs) words.lastObject.endMs = t;
                [words addObject:[IVLWord wordWithText:wt start:t end:0]];
            }
            text = @"";
        } else {
            text = rest;
        }
        if (words.count) {
            // Normalise word texts, then rebuild the line text from them so character
            // ranges used for karaoke drawing match the displayed string exactly.
            NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
            for (IVLWord *w in words) w.text = IVLCollapseWhitespace(w.text);
            for (NSUInteger i = 1; i < words.count; i++) {
                if ([words[i - 1].text hasSuffix:@" "] && [words[i].text hasPrefix:@" "]) words[i].text = [words[i].text substringFromIndex:1];
            }
            while (words.firstObject.text.length && [ws characterIsMember:[words.firstObject.text characterAtIndex:0]])
                words.firstObject.text = [words.firstObject.text substringFromIndex:1];
            words.lastObject.text = [words.lastObject.text stringByTrimmingCharactersInSet:ws];
            [words filterUsingPredicate:[NSPredicate predicateWithFormat:@"text.length > 0"]];
            NSMutableString *joined = [NSMutableString string];
            for (IVLWord *w in words) [joined appendString:w.text];
            text = joined;
        } else {
            text = [IVLCollapseWhitespace(text) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }

        for (NSNumber *t in times) {
            IVLLyricLine *l = [IVLLyricLine new];
            l.startMs = MAX(0, t.integerValue - offset);
            l.text = text;
            if (words.count && times.count == 1) {
                NSMutableArray *shifted = [NSMutableArray array];
                for (IVLWord *w in words) {
                    [shifted addObject:[IVLWord wordWithText:w.text start:MAX(0, w.startMs - offset) end:(w.endMs > 0 ? MAX(0, w.endMs - offset) : 0)]];
                }
                l.words = shifted;
            }
            [lines addObject:l];
        }
    }
    if (!lines.count) return nil;
    return IVLFinalize(lines, durationMs, NO);
}

#pragma mark - Plain

+ (IVLLyrics *)parsePlain:(NSString *)text {
    if (!text.length) return nil;
    NSString *normalized = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSMutableArray *lines = [NSMutableArray array];
    BOOL lastEmpty = YES;
    for (NSString *raw in [normalized componentsSeparatedByString:@"\n"]) {
        NSString *t = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        // strip stray LRC tags
        t = [t stringByReplacingOccurrencesOfString:@"^\\[[^\\]]*\\]" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, t.length)];
        if (!t.length) {
            if (lastEmpty) continue;
            lastEmpty = YES;
        } else lastEmpty = NO;
        IVLLyricLine *l = [IVLLyricLine new];
        l.text = t;
        [lines addObject:l];
    }
    while ([[lines.lastObject text] length] == 0 && lines.count) [lines removeLastObject];
    if (!lines.count) return nil;
    IVLLyrics *ly = [IVLLyrics new];
    ly.lines = lines;
    ly.synced = NO;
    return ly;
}

#pragma mark - TTML

+ (IVLLyrics *)parseTTML:(NSString *)ttml durationMs:(NSInteger)durationMs {
    if (!ttml.length) return nil;
    IVLTTMLDelegate *delegate = [IVLTTMLDelegate new];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:[ttml dataUsingEncoding:NSUTF8StringEncoding]];
    parser.delegate = delegate;
    parser.shouldProcessNamespaces = NO;
    [parser parse];
    NSMutableArray *lines = delegate.lines;
    if (!lines.count) return nil;
    BOOL anyTimed = NO;
    for (IVLLyricLine *l in lines) if (l.startMs > 0 || l.endMs > 0) { anyTimed = YES; break; }
    if (!anyTimed) {
        IVLLyrics *ly = [IVLLyrics new];
        ly.lines = lines;
        ly.synced = NO;
        return ly;
    }
    return IVLFinalize(lines, durationMs, YES);
}

@end

#pragma mark - TTML delegate

static NSInteger IVLParseClock(NSString *s) {
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!s.length) return -1;
    if ([s hasSuffix:@"ms"]) return (NSInteger)llround([[s substringToIndex:s.length - 2] doubleValue]);
    if ([s hasSuffix:@"s"]) return (NSInteger)llround([[s substringToIndex:s.length - 1] doubleValue] * 1000.0);
    NSArray<NSString *> *parts = [s componentsSeparatedByString:@":"];
    double total = 0;
    for (NSString *p in parts) total = total * 60.0 + p.doubleValue;
    return (NSInteger)llround(total * 1000.0);
}


@implementation IVLTTMLDelegate {
    IVLLyricLine *_line;
    NSMutableArray<IVLWord *> *_words;
    NSMutableString *_lineText;
    IVLWord *_word;
    NSMutableArray<NSNumber *> *_spanStack;  // YES = background-vocal context
    NSString *_primaryAgent;
    NSInteger _bodyDepth;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lines = [NSMutableArray array];
        _spanStack = [NSMutableArray array];
    }
    return self;
}

static NSString *IVLAttr(NSDictionary *attrs, NSString *localName) {
    for (NSString *k in attrs) {
        NSString *name = [k componentsSeparatedByString:@":"].lastObject;
        if ([name isEqualToString:localName]) return attrs[k];
    }
    return nil;
}

- (BOOL)inBackground {
    for (NSNumber *n in _spanStack) if (n.boolValue) return YES;
    return NO;
}

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)el namespaceURI:(NSString *)ns qualifiedName:(NSString *)qn attributes:(NSDictionary *)attrs {
    NSString *name = [el componentsSeparatedByString:@":"].lastObject;
    if ([name isEqualToString:@"body"]) { _bodyDepth++; return; }
    if (_bodyDepth == 0) return;

    if ([name isEqualToString:@"p"]) {
        _line = [IVLLyricLine new];
        NSString *b = IVLAttr(attrs, @"begin"), *e = IVLAttr(attrs, @"end");
        _line.startMs = b ? MAX(0, IVLParseClock(b)) : 0;
        _line.endMs = e ? MAX(0, IVLParseClock(e)) : 0;
        NSString *agent = IVLAttr(attrs, @"agent");
        if (agent.length) {
            if (!_primaryAgent) _primaryAgent = agent;
            _line.alternateVoice = ![agent isEqualToString:_primaryAgent];
        }
        _words = [NSMutableArray array];
        _lineText = [NSMutableString string];
        [_spanStack removeAllObjects];
        return;
    }
    if (!_line) return;

    if ([name isEqualToString:@"br"]) { [self appendText:@" "]; return; }
    if ([name isEqualToString:@"span"]) {
        NSString *role = IVLAttr(attrs, @"role");
        BOOL bg = [role isEqualToString:@"x-bg"] || [role isEqualToString:@"x-translation"] || [role isEqualToString:@"x-roman"];
        [_spanStack addObject:@(bg)];
        if ([self inBackground]) return;
        NSString *b = IVLAttr(attrs, @"begin");
        if (b) {
            NSString *e = IVLAttr(attrs, @"end");
            _word = [IVLWord wordWithText:@"" start:MAX(0, IVLParseClock(b)) end:e ? MAX(0, IVLParseClock(e)) : 0];
        }
    }
}

- (void)appendText:(NSString *)s {
    if (!_line || [self inBackground]) return;
    if (_word) { _word.text = [_word.text stringByAppendingString:s]; return; }
    if (_words.count) { IVLWord *last = _words.lastObject; last.text = [last.text stringByAppendingString:s]; return; }
    [_lineText appendString:s];
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    [self appendText:IVLCollapseWhitespace(string)];
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)el namespaceURI:(NSString *)ns qualifiedName:(NSString *)qn {
    NSString *name = [el componentsSeparatedByString:@":"].lastObject;
    if ([name isEqualToString:@"body"]) { _bodyDepth--; return; }
    if (!_line) return;

    if ([name isEqualToString:@"span"]) {
        BOOL wasBg = [self inBackground];
        if (_spanStack.count) [_spanStack removeLastObject];
        if (!wasBg && _word) {
            if (_word.text.length) [_words addObject:_word];
            _word = nil;
        }
        return;
    }
    if ([name isEqualToString:@"p"]) {
        NSString *text;
        if (_words.count) {
            NSMutableString *j = [NSMutableString string];
            if (_lineText.length) {
                _words.firstObject.text = [_lineText stringByAppendingString:_words.firstObject.text];
            }
            for (IVLWord *w in _words) [j appendString:w.text];
            text = j;
            _words.lastObject.text = [_words.lastObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            IVLWord *first = _words.firstObject;
            while (first.text.length && [[NSCharacterSet whitespaceCharacterSet] characterIsMember:[first.text characterAtIndex:0]]) {
                first.text = [first.text substringFromIndex:1];
            }
            _line.words = _words;
        } else {
            text = _lineText;
        }
        _line.text = [IVLCollapseWhitespace(text) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (_line.text.length) {
            if (_line.words.count) {
                // Rebuild text from words so ranges line up exactly with what is drawn.
                NSMutableString *j = [NSMutableString string];
                for (IVLWord *w in _line.words) [j appendString:w.text];
                _line.text = j;
            }
            [_lines addObject:_line];
        }
        _line = nil; _words = nil; _lineText = nil; _word = nil;
    }
}

@end
