#import "IVLTranslator.h"
#import "IVLSettings.h"
#import "IVLAppleIntelAssets.h"
#import <CommonCrypto/CommonDigest.h>

@protocol IVLAppleTranslationBridgeProtocol <NSObject>
+ (BOOL)isAppleTranslationAvailable;
+ (BOOL)isAppleIntelligenceAvailable;
+ (NSString *)appleIntelligenceStatus;
+ (void)translateWithAppleTranslationWithLines:(NSArray<NSString *> *)lines
                                    sourceLang:(nullable NSString *)sourceLang
                                    targetLang:(NSString *)targetLang
                                    completion:(void (^)(NSArray<NSString *> *_Nullable))completion;
+ (void)translateWithAppleIntelligenceWithLines:(NSArray<NSString *> *)lines
                                     targetLang:(NSString *)targetLang
                                     completion:(void (^)(NSArray<NSString *> *_Nullable))completion;
@end

static Class IVLAppleBridgeClass(void) {
    return NSClassFromString(@"IVLAppleTranslationBridge");
}

BOOL IVLIsAppleTranslationAvailable(void) {
    Class cls = IVLAppleBridgeClass();
    if (!cls || ![cls respondsToSelector:@selector(isAppleTranslationAvailable)]) return NO;
    return [(id<IVLAppleTranslationBridgeProtocol>)cls isAppleTranslationAvailable];
}

BOOL IVLIsAppleIntelligenceAvailable(void) {
    Class cls = IVLAppleBridgeClass();
    if (!cls || ![cls respondsToSelector:@selector(isAppleIntelligenceAvailable)]) return NO;
    return [(id<IVLAppleTranslationBridgeProtocol>)cls isAppleIntelligenceAvailable];
}

NSString *IVLAppleIntelligenceStatusCode(void) {
    Class cls = IVLAppleBridgeClass();
    if (!cls || ![cls respondsToSelector:@selector(appleIntelligenceStatus)]) return @"no_bridge";
    return [(id<IVLAppleTranslationBridgeProtocol>)cls appleIntelligenceStatus] ?: @"unknown";
}

UIImage *IVLAppleIntelligenceIconImage(void) {
    static UIImage *img = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSData *d = [NSData dataWithBytesNoCopy:(void *)kIVLAppleIntelIconPNG length:kIVLAppleIntelIconPNGLen freeWhenDone:NO];
        UIImage *raw = [UIImage imageWithData:d scale:3.0];
        img = [raw imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    });
    return img;
}

static UIImage *IVLAppleIntelligenceGlowFull(void) {
    static UIImage *img = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSData *d = [NSData dataWithBytesNoCopy:(void *)kIVLAppleIntelGlowPNG length:kIVLAppleIntelGlowPNGLen freeWhenDone:NO];
        img = [UIImage imageWithData:d scale:2.0];
    });
    return img;
}

UIImage *IVLAppleIntelligenceTopGlowImage(void) {
    static UIImage *img = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGImageRef cg = IVLAppleIntelligenceGlowFull().CGImage;
        if (!cg) return;
        size_t w = CGImageGetWidth(cg);
        size_t h = CGImageGetHeight(cg);
        CGImageRef crop = CGImageCreateWithImageInRect(cg, CGRectMake(0, 0, w, h / 2));
        if (crop) {
            img = [[UIImage imageWithCGImage:crop scale:2.0 orientation:UIImageOrientationUp] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
            CGImageRelease(crop);
        }
    });
    return img;
}

UIImage *IVLAppleIntelligenceBottomGlowImage(void) {
    static UIImage *img = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGImageRef cg = IVLAppleIntelligenceGlowFull().CGImage;
        if (!cg) return;
        size_t w = CGImageGetWidth(cg);
        size_t h = CGImageGetHeight(cg);
        CGImageRef crop = CGImageCreateWithImageInRect(cg, CGRectMake(0, h / 2, w, h - h / 2));
        if (crop) {
            img = [[UIImage imageWithCGImage:crop scale:2.0 orientation:UIImageOrientationUp] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
            CGImageRelease(crop);
        }
    });
    return img;
}

static NSString *const kEndpoint = @"https://translate.googleapis.com/translate_a/single";
static const NSUInteger kChunkLines = 30;
static const NSUInteger kChunkChars = 1500;

@implementation IVLTranslator {
    NSURLSession *_session;
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *_memory;
    NSMutableSet<NSString *> *_inflight;
}

+ (instancetype)shared {
    static IVLTranslator *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [self new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest = 12;
        _session = [NSURLSession sessionWithConfiguration:cfg];
        _memory = [NSMutableDictionary dictionary];
        _inflight = [NSMutableSet set];
    }
    return self;
}

static NSString *IVLHash(NSString *s) {
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char out[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(d.bytes, (CC_LONG)d.length, out);
    NSMutableString *h = [NSMutableString string];
    for (int i = 0; i < 8; i++) [h appendFormat:@"%02x", out[i]];
    return h;
}

- (NSString *)cacheDir {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [base stringByAppendingPathComponent:@"ivLyricsYTM/translations"];
}

- (void)clearCache {
    @synchronized (self) { [_memory removeAllObjects]; }
    [[NSFileManager defaultManager] removeItemAtPath:[self cacheDir] error:nil];
}

#pragma mark - Request

- (void)requestText:(NSString *)text target:(NSString *)lang completion:(void (^)(NSString *_Nullable))completion {
    NSURLComponents *c = [NSURLComponents componentsWithString:kEndpoint];
    c.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"client" value:@"gtx"],
        [NSURLQueryItem queryItemWithName:@"sl" value:@"auto"],
        [NSURLQueryItem queryItemWithName:@"tl" value:lang],
        [NSURLQueryItem queryItemWithName:@"dt" value:@"t"],
    ];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:c.URL];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/x-www-form-urlencoded;charset=UTF-8" forHTTPHeaderField:@"Content-Type"];
    NSMutableCharacterSet *allowed = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [allowed addCharactersInString:@"-._~"];
    NSString *body = [@"q=" stringByAppendingString:[text stringByAddingPercentEncodingWithAllowedCharacters:allowed]];
    req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

    [[_session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![json isKindOfClass:[NSArray class]] || ![[json firstObject] isKindOfClass:[NSArray class]]) { completion(nil); return; }
        NSMutableString *out = [NSMutableString string];
        for (id seg in [json firstObject]) {
            if ([seg isKindOfClass:[NSArray class]] && [seg count] && [seg[0] isKindOfClass:[NSString class]]) [out appendString:seg[0]];
        }
        completion([out stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]);
    }] resume];
}

- (void)translateLines:(NSArray<NSString *> *)lines target:(NSString *)lang completion:(void (^)(NSArray<NSString *> *_Nullable))completion {
    // chunking
    NSMutableArray<NSArray<NSString *> *> *chunks = [NSMutableArray array];
    NSMutableArray *cur = [NSMutableArray array];
    NSUInteger chars = 0;
    for (NSString *l in lines) {
        if (cur.count && (cur.count >= kChunkLines || chars + l.length + 1 > kChunkChars)) {
            [chunks addObject:cur]; cur = [NSMutableArray array]; chars = 0;
        }
        [cur addObject:l]; chars += l.length + 1;
    }
    if (cur.count) [chunks addObject:cur];

    NSMutableArray *results = [NSMutableArray arrayWithCapacity:chunks.count];
    for (NSUInteger i = 0; i < chunks.count; i++) [results addObject:[NSNull null]];
    dispatch_group_t group = dispatch_group_create();
    __block BOOL failed = NO;

    for (NSUInteger ci = 0; ci < chunks.count; ci++) {
        NSArray<NSString *> *chunk = chunks[ci];
        dispatch_group_enter(group);
        [self requestText:[chunk componentsJoinedByString:@"\n"] target:lang completion:^(NSString *translated) {
            NSMutableArray *split = [[translated componentsSeparatedByString:@"\n"] mutableCopy];
            if (split.count == chunk.count + 1 && [split.lastObject length] == 0) [split removeLastObject];
            if (translated && split.count == chunk.count) {
                @synchronized (results) { results[ci] = split; }
                dispatch_group_leave(group);
                return;
            }
            // Line count mismatch -> translate line by line
            NSMutableArray *single = [NSMutableArray arrayWithCapacity:chunk.count];
            for (NSUInteger k = 0; k < chunk.count; k++) [single addObject:@""];
            dispatch_group_t g2 = dispatch_group_create();
            for (NSUInteger k = 0; k < chunk.count; k++) {
                dispatch_group_enter(g2);
                [self requestText:chunk[k] target:lang completion:^(NSString *t) {
                    @synchronized (single) { single[k] = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @""; }
                    if (!t) failed = YES;
                    dispatch_group_leave(g2);
                }];
            }
            dispatch_group_notify(g2, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                @synchronized (results) { results[ci] = single; }
                dispatch_group_leave(group);
            });
        }];
    }

    dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (failed) { completion(nil); return; }
        NSMutableArray *flat = [NSMutableArray array];
        for (NSArray *r in results) [flat addObjectsFromArray:r];
        completion(flat.count == lines.count ? flat : nil);
    });
}

#pragma mark - Public

- (void)translateLyrics:(IVLLyrics *)lyrics videoID:(NSString *)videoID target:(NSString *)lang completion:(void (^)(BOOL))completion {
    NSMutableArray<IVLLyricLine *> *targets = [NSMutableArray array];
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (IVLLyricLine *l in lyrics.lines) {
        if (!l.instrumental && l.text.length) { [targets addObject:l]; [texts addObject:l.text]; }
    }
    void (^apply)(NSArray<NSString *> *) = ^(NSArray<NSString *> *tr) {
        for (NSUInteger i = 0; i < targets.count && i < tr.count; i++) {
            NSString *t = [tr[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            // hide translations identical to the original (already in target language)
            targets[i].translation = (t.length && ![t isEqualToString:targets[i].text]) ? t : nil;
        }
    };

    if (!texts.count) { completion(NO); return; }
    // skip when lyrics are already in the target language
    NSString *src = lyrics.language;
    if (src.length && ([lang hasPrefix:src] || [src hasPrefix:lang])) {
        for (IVLLyricLine *l in targets) l.translation = nil;
        completion(NO);
        return;
    }

    IVLTranslationEngine engine = (IVLTranslationEngine)[IVLSettings integerForKey:IVLKeyTranslationEngine];
    if (engine == IVLTranslationEngineAppleIntelligence && !IVLIsAppleIntelligenceAvailable()) {
        engine = IVLIsAppleTranslationAvailable() ? IVLTranslationEngineApple : IVLTranslationEngineGoogle;
    } else if (engine == IVLTranslationEngineApple && !IVLIsAppleTranslationAvailable()) {
        engine = IVLTranslationEngineGoogle;
    }

    NSString *engineTag = (engine == IVLTranslationEngineAppleIntelligence) ? @"ai" : (engine == IVLTranslationEngineApple ? @"apple" : @"google");
    NSString *key = [NSString stringWithFormat:@"%@_%@_%@_%@", engineTag, videoID ?: @"x", lang, IVLHash([texts componentsJoinedByString:@"\n"])];
    NSArray *cached;
    @synchronized (self) { cached = _memory[key]; }
    if (!cached) {
        NSString *path = [[self cacheDir] stringByAppendingPathComponent:[key stringByAppendingPathExtension:@"json"]];
        NSData *d = [NSData dataWithContentsOfFile:path];
        id json = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        if ([json isKindOfClass:[NSArray class]] && [json count] == texts.count) cached = json;
    }
    if (cached) {
        @synchronized (self) { _memory[key] = cached; }
        apply(cached);
        completion(YES);
        return;
    }
    @synchronized (self) {
        if ([_inflight containsObject:key]) return;   // the first caller gets notified
        [_inflight addObject:key];
    }

    void (^finish)(NSArray<NSString *> *) = ^(NSArray<NSString *> *tr) {
        @synchronized (self) {
            [self->_inflight removeObject:key];
            if (tr) self->_memory[key] = tr;
        }
        if (tr) {
            NSString *dir = [self cacheDir];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            [[NSJSONSerialization dataWithJSONObject:tr options:0 error:nil] writeToFile:[dir stringByAppendingPathComponent:[key stringByAppendingPathExtension:@"json"]] atomically:YES];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (tr) apply(tr);
            completion(tr != nil);
        });
    };

    Class bridge = IVLAppleBridgeClass();
    if (engine == IVLTranslationEngineAppleIntelligence && [bridge respondsToSelector:@selector(translateWithAppleIntelligenceWithLines:targetLang:completion:)]) {
        [(id<IVLAppleTranslationBridgeProtocol>)bridge translateWithAppleIntelligenceWithLines:texts targetLang:lang completion:^(NSArray<NSString *> *tr) {
            if (tr.count == texts.count) { finish(tr); return; }
            // Graceful fallback to Apple Translation if Foundation Models hits a guardrail/context limit
            if (IVLIsAppleTranslationAvailable() && [bridge respondsToSelector:@selector(translateWithAppleTranslationWithLines:sourceLang:targetLang:completion:)]) {
                [(id<IVLAppleTranslationBridgeProtocol>)bridge translateWithAppleTranslationWithLines:texts sourceLang:src.length ? src : nil targetLang:lang completion:^(NSArray<NSString *> *tr2) {
                    if (tr2.count == texts.count) finish(tr2);
                    else [self translateLines:texts target:lang completion:finish];
                }];
            } else {
                [self translateLines:texts target:lang completion:finish];
            }
        }];
    } else if (engine == IVLTranslationEngineApple && [bridge respondsToSelector:@selector(translateWithAppleTranslationWithLines:sourceLang:targetLang:completion:)]) {
        [(id<IVLAppleTranslationBridgeProtocol>)bridge translateWithAppleTranslationWithLines:texts sourceLang:src.length ? src : nil targetLang:lang completion:^(NSArray<NSString *> *tr) {
            if (tr.count == texts.count) finish(tr);
            else [self translateLines:texts target:lang completion:finish];
        }];
    } else {
        [self translateLines:texts target:lang completion:finish];
    }
}

@end

#pragma mark - Pronunciation

@implementation IVLPronunciation

static BOOL IVLHasKana(NSString *s) { return [s rangeOfString:@"[\\u3040-\\u30ff]" options:NSRegularExpressionSearch].location != NSNotFound; }
static BOOL IVLHasHangul(NSString *s) { return [s rangeOfString:@"[\\u1100-\\u11ff\\u3130-\\u318f\\uac00-\\ud7af]" options:NSRegularExpressionSearch].location != NSNotFound; }
static BOOL IVLHasHan(NSString *s) { return [s rangeOfString:@"[\\u3400-\\u4dbf\\u4e00-\\u9fff\\uf900-\\ufaff]" options:NSRegularExpressionSearch].location != NSNotFound; }
static BOOL IVLIsMostlyLatin(NSString *s) {
    NSUInteger letters = 0, latin = 0;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (![[NSCharacterSet letterCharacterSet] characterIsMember:c]) continue;
        letters++;
        if (c < 0x0250 || (c >= 0x1E00 && c <= 0x1EFF)) latin++;
    }
    return letters == 0 || latin * 10 >= letters * 9;
}

static NSString *IVLTransform(NSString *s, CFStringRef transform) {
    NSMutableString *m = [s mutableCopy];
    CFStringTransform((__bridge CFMutableStringRef)m, NULL, transform, false);
    return m;
}

+ (NSString *)japanese:(NSString *)text kana:(BOOL)kana {
    CFLocaleRef locale = CFLocaleCreate(kCFAllocatorDefault, CFSTR("ja"));
    CFStringTokenizerRef tok = CFStringTokenizerCreate(kCFAllocatorDefault, (__bridge CFStringRef)text,
                                                       CFRangeMake(0, text.length), kCFStringTokenizerUnitWordBoundary, locale);
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSMutableString *kanaOut = [NSMutableString string];
    CFIndex lastEnd = 0;
    CFStringTokenizerTokenType type;
    while ((type = CFStringTokenizerAdvanceToNextToken(tok)) != kCFStringTokenizerTokenNone) {
        CFRange r = CFStringTokenizerGetCurrentTokenRange(tok);
        if (r.location > lastEnd) [kanaOut appendString:[text substringWithRange:NSMakeRange(lastEnd, r.location - lastEnd)]];
        NSString *surface = [text substringWithRange:NSMakeRange(r.location, r.length)];
        NSString *latin = CFBridgingRelease(CFStringTokenizerCopyCurrentTokenAttribute(tok, kCFStringTokenizerAttributeLatinTranscription));
        BOOL needs = IVLHasKana(surface) || IVLHasHan(surface);
        if (!needs || !latin.length) {
            [parts addObject:surface];
            [kanaOut appendString:surface];
        } else if (kana) {
            [kanaOut appendString:IVLHasHan(surface) ? IVLTransform(latin, kCFStringTransformLatinHiragana) : surface];
        } else {
            [parts addObject:latin];
        }
        lastEnd = r.location + r.length;
    }
    if (lastEnd < (CFIndex)text.length) [kanaOut appendString:[text substringFromIndex:lastEnd]];
    CFRelease(tok);
    CFRelease(locale);
    if (kana) return kanaOut;
    NSString *joined = [parts componentsJoinedByString:@" "];
    // tidy spaces before punctuation
    joined = [joined stringByReplacingOccurrencesOfString:@"\\s+([,.!?、。！？」』）)])" withString:@"$1" options:NSRegularExpressionSearch range:NSMakeRange(0, joined.length)];
    return joined;
}

+ (NSString *)pronunciationForText:(NSString *)text language:(NSString *)lang mode:(NSInteger)mode {
    if (mode == 0 || !text.length) return nil;
    BOOL ja = IVLHasKana(text) || ([lang hasPrefix:@"ja"] && IVLHasHan(text));
    NSString *out = nil;
    if (ja) {
        out = [self japanese:text kana:(mode == 2)];
    } else if (IVLIsMostlyLatin(text)) {
        return nil;
    } else if (IVLHasHangul(text)) {
        out = IVLTransform(text, kCFStringTransformToLatin);
    } else {
        out = IVLTransform(text, kCFStringTransformToLatin);   // pinyin with tone marks, Cyrillic, Greek, Thai, ...
    }
    out = [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!out.length || [out isEqualToString:text]) return nil;
    return out;
}

+ (void)applyToLyrics:(IVLLyrics *)lyrics mode:(NSInteger)mode {
    for (IVLLyricLine *l in lyrics.lines) {
        l.pronunciation = l.instrumental ? nil : [self pronunciationForText:l.text language:lyrics.language mode:mode];
    }
}

@end
