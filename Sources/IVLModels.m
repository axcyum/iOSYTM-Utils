#import "IVLModels.h"

@implementation IVLWord
+ (instancetype)wordWithText:(NSString *)text start:(NSInteger)start end:(NSInteger)end {
    IVLWord *w = [self new];
    w.text = text ?: @"";
    w.startMs = start;
    w.endMs = end;
    return w;
}
@end

@implementation IVLLyricLine
@end

@implementation IVLLyrics

- (NSInteger)indexOfLineAtTime:(NSInteger)ms {
    NSArray *lines = self.lines;
    NSInteger lo = 0, hi = (NSInteger)lines.count - 1, found = -1;
    while (lo <= hi) {
        NSInteger mid = (lo + hi) / 2;
        if (((IVLLyricLine *)lines[mid]).startMs <= ms) { found = mid; lo = mid + 1; }
        else hi = mid - 1;
    }
    return found;
}

- (NSString *)plainText {
    NSMutableArray *a = [NSMutableArray array];
    for (IVLLyricLine *l in self.lines) if (!l.instrumental) [a addObject:l.text];
    return [a componentsJoinedByString:@"\n"];
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableArray *lines = [NSMutableArray array];
    for (IVLLyricLine *l in self.lines) {
        NSMutableDictionary *d = [@{ @"s": @(l.startMs), @"e": @(l.endMs), @"t": l.text ?: @"" } mutableCopy];
        if (l.instrumental) d[@"i"] = @YES;
        if (l.alternateVoice) d[@"a"] = @YES;
        if (l.words.count) {
            NSMutableArray *ws = [NSMutableArray array];
            for (IVLWord *w in l.words) [ws addObject:@[w.text, @(w.startMs), @(w.endMs)]];
            d[@"w"] = ws;
        }
        [lines addObject:d];
    }
    return @{ @"v": @1, @"lines": lines, @"synced": @(self.synced), @"karaoke": @(self.karaoke),
              @"source": self.source ?: @"", @"lang": self.language ?: @"", @"manual": @(self.manual) };
}

+ (instancetype)lyricsWithDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]] || [dict[@"v"] integerValue] != 1) return nil;
    NSArray *raw = dict[@"lines"];
    if (![raw isKindOfClass:[NSArray class]]) return nil;
    NSMutableArray *lines = [NSMutableArray array];
    for (NSDictionary *d in raw) {
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        IVLLyricLine *l = [IVLLyricLine new];
        l.startMs = [d[@"s"] integerValue];
        l.endMs = [d[@"e"] integerValue];
        l.text = [d[@"t"] isKindOfClass:[NSString class]] ? d[@"t"] : @"";
        l.instrumental = [d[@"i"] boolValue];
        l.alternateVoice = [d[@"a"] boolValue];
        NSArray *ws = d[@"w"];
        if ([ws isKindOfClass:[NSArray class]] && ws.count) {
            NSMutableArray *words = [NSMutableArray array];
            for (NSArray *w in ws) {
                if ([w isKindOfClass:[NSArray class]] && w.count == 3)
                    [words addObject:[IVLWord wordWithText:w[0] start:[w[1] integerValue] end:[w[2] integerValue]]];
            }
            l.words = words;
        }
        [lines addObject:l];
    }
    IVLLyrics *ly = [self new];
    ly.lines = lines;
    ly.synced = [dict[@"synced"] boolValue];
    ly.karaoke = [dict[@"karaoke"] boolValue];
    ly.source = dict[@"source"] ?: @"";
    NSString *lang = dict[@"lang"];
    ly.language = lang.length ? lang : nil;
    ly.manual = [dict[@"manual"] boolValue];
    return ly;
}

@end

@implementation IVLTrack
@end
