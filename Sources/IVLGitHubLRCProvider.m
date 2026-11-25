#import "IVLLyricsService+Private.h"
#import "IVLLyricsParser.h"
#import "IVLSettings.h"

static NSMutableDictionary<NSString *, NSArray<NSDictionary *> *> *gGHIndexCache;
static NSMutableDictionary<NSString *, NSDate *> *gGHIndexStamp;
static dispatch_queue_t gGHQueue;

static void IVLGHInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gGHIndexCache = [NSMutableDictionary dictionary];
        gGHIndexStamp = [NSMutableDictionary dictionary];
        gGHQueue = dispatch_queue_create("ivlyrics.githublrc", DISPATCH_QUEUE_SERIAL);
    });
}

static NSString *IVLGHFold(NSString *s) {
    if (!s.length) return @"";
    NSString *f = [[s precomposedStringWithCompatibilityMapping] lowercaseString];
    f = [f stringByReplacingOccurrencesOfString:@"[–—―‐−_]" withString:@"-" options:NSRegularExpressionSearch range:NSMakeRange(0, f.length)];
    f = [f stringByReplacingOccurrencesOfString:@"\\s+" withString:@" " options:NSRegularExpressionSearch range:NSMakeRange(0, f.length)];
    return [f stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *IVLGHNorm(NSString *s) {
    if (!s.length) return @"";
    NSString *f = [[s precomposedStringWithCompatibilityMapping] lowercaseString];
    f = [f stringByFoldingWithOptions:NSDiacriticInsensitiveSearch locale:nil];
    NSCharacterSet *strip = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    return [[f componentsSeparatedByCharactersInSet:strip] componentsJoinedByString:@""];
}

static NSString *IVLDecodeLyricsText(NSData *data) {
    if (!data.length) return nil;
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!s) s = [[NSString alloc] initWithData:data encoding:NSShiftJISStringEncoding];
    if (!s) s = [[NSString alloc] initWithData:data encoding:NSUTF16StringEncoding];
    if (!s) s = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if ([s hasPrefix:@"\uFEFF"]) s = [s substringFromIndex:1];
    return s;
}

static NSInteger IVLExtPriority(NSString *ext) {
    NSString *e = ext.lowercaseString;
    if ([e isEqualToString:@"lrc"]) return 3;
    if ([e isEqualToString:@"ttml"]) return 2;
    if ([e isEqualToString:@"txt"]) return 1;
    return 0;
}

@implementation IVLLyricsService (GitHubLRC)

+ (NSString *)parseGitHubOwnerRepo:(NSString *)raw extractedBranch:(NSString *__autoreleasing  _Nullable *)outBranch {
    if (outBranch) *outBranch = nil;
    NSString *s = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!s.length) return nil;

    // Accept "https://github.com/owner/repo", "github.com/owner/repo/tree/main", "owner/repo.git", or "owner/repo"
    if ([s hasPrefix:@"http://"] || [s hasPrefix:@"https://"]) {
        NSURL *u = [NSURL URLWithString:s];
        if (!u || ![u.host.lowercaseString containsString:@"github.com"]) return nil;
        s = u.path ?: @"";
    } else if ([s.lowercaseString hasPrefix:@"github.com/"]) {
        s = [s substringFromIndex:@"github.com/".length];
    }

    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    NSArray<NSString *> *parts = [s componentsSeparatedByString:@"/"];
    if (parts.count < 2) return nil;

    NSString *owner = parts[0];
    NSString *repo = parts[1];
    if ([repo.lowercaseString hasSuffix:@".git"]) repo = [repo substringToIndex:repo.length - 4];
    if (!owner.length || !repo.length) return nil;

    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    if ([owner rangeOfCharacterFromSet:[allowed invertedSet]].location != NSNotFound) return nil;
    if ([repo rangeOfCharacterFromSet:[allowed invertedSet]].location != NSNotFound) return nil;

    if (parts.count >= 4 && ([parts[2] isEqualToString:@"tree"] || [parts[2] isEqualToString:@"blob"])) {
        if (outBranch) *outBranch = parts[3];
    }
    return [NSString stringWithFormat:@"%@/%@", owner, repo];
}

+ (IVLLyrics *)parseLyricsData:(NSData *)data fileName:(NSString *)fileName durationMs:(NSInteger)durMs {
    NSString *text = IVLDecodeLyricsText(data);
    if (!text.length) return nil;
    NSString *ext = fileName.pathExtension.lowercaseString;
    IVLLyrics *ly = nil;
    if ([ext isEqualToString:@"ttml"] || [text containsString:@"<tt "] || [text containsString:@"<body"]) {
        ly = [IVLLyricsParser parseTTML:text durationMs:durMs];
    }
    if (!ly.lines.count) ly = [IVLLyricsParser parseLRC:text durationMs:durMs];
    if (!ly.lines.count) ly = [IVLLyricsParser parsePlain:text];
    return ly.lines.count ? ly : nil;
}

- (void)invalidateGitHubLRCCache {
    IVLGHInit();
    dispatch_async(gGHQueue, ^{
        [gGHIndexCache removeAllObjects];
        [gGHIndexStamp removeAllObjects];
    });
}

- (void)fetchGitHubRootFilesForRepo:(NSString *)ownerRepo
                             branch:(nullable NSString *)branch
                        bypassCache:(BOOL)bypass
                         completion:(void (^)(NSArray<NSDictionary *> *_Nullable files, NSError *_Nullable error))done {
    IVLGHInit();
    NSString *cacheKey = [NSString stringWithFormat:@"%@|%@", ownerRepo.lowercaseString, branch ?: @""];
    if (!bypass) {
        __block NSArray<NSDictionary *> *cached = nil;
        dispatch_sync(gGHQueue, ^{
            NSDate *ts = gGHIndexStamp[cacheKey];
            if (ts && -[ts timeIntervalSinceNow] < 600.0) cached = gGHIndexCache[cacheKey];
        });
        if (cached) { done(cached, nil); return; }
    }

    NSString *urlStr = [NSString stringWithFormat:@"https://api.github.com/repos/%@/contents", ownerRepo];
    if (branch.length) {
        NSString *enc = [branch stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
        urlStr = [urlStr stringByAppendingFormat:@"?ref=%@", enc ?: branch];
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    [req setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [req setValue:@"iOSYTM-Utils" forHTTPHeaderField:@"User-Agent"];
    req.timeoutInterval = 12.0;

    NSURLSession *sess = [NSURLSession sharedSession];
    [[sess dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSInteger code = [resp isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        if (code != 200 || !data.length) {
            NSError *e = err ?: [NSError errorWithDomain:@"IVLGitHubLRC" code:(code ?: -1) userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"GitHub API HTTP %ld", (long)code]
            }];
            done(nil, e);
            return;
        }
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:[NSArray class]]) {
            NSError *e = [NSError errorWithDomain:@"IVLGitHubLRC" code:-2 userInfo:@{ NSLocalizedDescriptionKey: @"Invalid GitHub response" }];
            done(nil, e);
            return;
        }
        NSMutableArray<NSDictionary *> *files = [NSMutableArray array];
        for (id item in (NSArray *)json) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *d = item;
            if (![d[@"type"] isEqualToString:@"file"]) continue;
            NSString *name = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : @"";
            NSString *dl = [d[@"download_url"] isKindOfClass:[NSString class]] ? d[@"download_url"] : @"";
            if (!name.length || !dl.length) continue;
            NSInteger prio = IVLExtPriority(name.pathExtension);
            if (prio <= 0) continue;
            NSString *base = [name stringByDeletingPathExtension];
            [files addObject:@{
                @"name": name,
                @"baseFold": IVLGHFold(base),
                @"baseNorm": IVLGHNorm(base),
                @"extPrio": @(prio),
                @"url": dl,
            }];
        }
        dispatch_async(gGHQueue, ^{
            gGHIndexCache[cacheKey] = files;
            gGHIndexStamp[cacheKey] = [NSDate date];
        });
        done(files, nil);
    }] resume];
}

static NSDictionary *IVLMatchGitHubFile(NSArray<NSDictionary *> *files, IVLTrack *track) {
    if (!files.count || !track) return nil;
    NSString *vidFold = track.youtubeVideoID.length ? track.youtubeVideoID.lowercaseString : @"";
    NSString *rawTitle = track.title ?: @"";
    NSString *rawArtist = track.artist ?: @"";
    NSString *cleanTitle = [IVLLyricsService cleanTitle:rawTitle];
    NSString *cleanArtist = [IVLLyricsService cleanArtist:rawArtist];

    NSString *ctFold = IVLGHFold(cleanTitle);
    NSString *rtFold = IVLGHFold(rawTitle);
    NSString *caFold = IVLGHFold(cleanArtist);
    NSString *raFold = IVLGHFold(rawArtist);

    NSString *ctNorm = IVLGHNorm(cleanTitle);
    NSString *rtNorm = IVLGHNorm(rawTitle);
    NSString *caNorm = IVLGHNorm(cleanArtist);
    NSString *raNorm = IVLGHNorm(rawArtist);

    NSMutableSet<NSString *> *comboFolds = [NSMutableSet set];
    NSMutableSet<NSString *> *comboNorms = [NSMutableSet set];
    NSArray<NSString *> *artists = [IVLLyricsService artistCandidates:rawArtist];
    NSMutableArray<NSString *> *artistPool = [artists mutableCopy] ?: [NSMutableArray array];
    if (rawArtist.length && ![artistPool containsObject:rawArtist]) [artistPool addObject:rawArtist];

    for (NSString *a in artistPool) {
        NSString *af = IVLGHFold(a);
        NSString *an = IVLGHNorm(a);
        if (!af.length) continue;
        for (NSString *tf in @[ctFold, rtFold]) {
            if (!tf.length) continue;
            [comboFolds addObject:[NSString stringWithFormat:@"%@ - %@", af, tf]];
            [comboFolds addObject:[NSString stringWithFormat:@"%@-%@", af, tf]];
            [comboFolds addObject:[NSString stringWithFormat:@"%@ - %@", tf, af]];
            [comboFolds addObject:[NSString stringWithFormat:@"%@-%@", tf, af]];
        }
        if (an.length) {
            for (NSString *tn in @[ctNorm, rtNorm]) {
                if (!tn.length) continue;
                [comboNorms addObject:[an stringByAppendingString:tn]];
                [comboNorms addObject:[tn stringByAppendingString:an]];
            }
        }
    }
    if (caFold.length && ctFold.length) {
        [comboFolds addObject:[NSString stringWithFormat:@"%@ - %@", caFold, ctFold]];
        [comboFolds addObject:[NSString stringWithFormat:@"%@ - %@", ctFold, caFold]];
    }
    if (raFold.length && rtFold.length) {
        [comboFolds addObject:[NSString stringWithFormat:@"%@ - %@", raFold, rtFold]];
        [comboFolds addObject:[NSString stringWithFormat:@"%@ - %@", rtFold, raFold]];
    }
    if (caNorm.length && ctNorm.length) {
        [comboNorms addObject:[caNorm stringByAppendingString:ctNorm]];
        [comboNorms addObject:[ctNorm stringByAppendingString:caNorm]];
    }
    if (raNorm.length && rtNorm.length) {
        [comboNorms addObject:[raNorm stringByAppendingString:rtNorm]];
        [comboNorms addObject:[rtNorm stringByAppendingString:raNorm]];
    }

    NSDictionary *best = nil;
    NSInteger bestScore = 0;
    NSInteger bestExt = 0;

    for (NSDictionary *f in files) {
        NSString *bf = f[@"baseFold"];
        NSString *bn = f[@"baseNorm"];
        NSInteger ep = [f[@"extPrio"] integerValue];
        NSInteger score = 0;

        if (vidFold.length && [bf isEqualToString:vidFold]) {
            score = 100;
        } else if (bf.length && [comboFolds containsObject:bf]) {
            score = 95;
        } else if (bn.length && [comboNorms containsObject:bn]) {
            score = 90;
        } else if (bf.length && ((ctFold.length && [bf isEqualToString:ctFold]) || (rtFold.length && [bf isEqualToString:rtFold]))) {
            score = 85;
        } else if (bn.length >= 2 && ((ctNorm.length >= 2 && [bn isEqualToString:ctNorm]) || (rtNorm.length >= 2 && [bn isEqualToString:rtNorm]))) {
            score = 80;
        }

        if (score > bestScore || (score > 0 && score == bestScore && ep > bestExt)) {
            bestScore = score;
            bestExt = ep;
            best = f;
        }
    }
    return best;
}

- (void)githubLRCForTrack:(IVLTrack *)track completion:(IVLLyricsCompletion)done {
    NSString *raw = [IVLSettings objectForKey:IVLKeyGitHubLRCRepo];
    NSString *extractedBranch = nil;
    NSString *ownerRepo = [IVLLyricsService parseGitHubOwnerRepo:raw extractedBranch:&extractedBranch];
    if (!ownerRepo.length) { done(nil, nil); return; }

    NSString *cfgBranch = [[IVLSettings objectForKey:IVLKeyGitHubLRCBranch] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *branch = cfgBranch.length ? cfgBranch : extractedBranch;

    [self fetchGitHubRootFilesForRepo:ownerRepo branch:branch bypassCache:NO completion:^(NSArray<NSDictionary *> *files, NSError *err) {
        if (err || !files.count) { done(nil, err); return; }
        NSDictionary *match = IVLMatchGitHubFile(files, track);
        if (!match) { done(nil, nil); return; }

        NSURL *dlURL = [NSURL URLWithString:match[@"url"]];
        if (!dlURL) { done(nil, nil); return; }
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:dlURL];
        [req setValue:@"iOSYTM-Utils" forHTTPHeaderField:@"User-Agent"];
        req.timeoutInterval = 12.0;

        [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *dlErr) {
            NSInteger code = [resp isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
            if (code != 200 || !data.length) { done(nil, dlErr); return; }
            IVLLyrics *ly = [IVLLyricsService parseLyricsData:data fileName:match[@"name"] durationMs:(NSInteger)(track.duration * 1000)];
            if (ly) ly.source = [NSString stringWithFormat:@"GitHub (%@)", ownerRepo];
            done(ly, nil);
        }] resume];
    }];
}

- (void)verifyGitHubLRCRepo:(NSString *)raw
                     branch:(nullable NSString *)branch
                 completion:(void (^)(BOOL ok, NSUInteger fileCount, NSString *_Nullable normalizedRepo, NSString *_Nullable errorMsg))completion {
    NSString *extractedBranch = nil;
    NSString *ownerRepo = [IVLLyricsService parseGitHubOwnerRepo:raw extractedBranch:&extractedBranch];
    if (!ownerRepo.length) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(NO, 0, nil, @"Invalid format (use owner/repo or GitHub URL)");
        });
        return;
    }
    NSString *b = [branch stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!b.length) b = extractedBranch;
    [self fetchGitHubRootFilesForRepo:ownerRepo branch:b bypassCache:YES completion:^(NSArray<NSDictionary *> *files, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (err) completion(NO, 0, ownerRepo, err.localizedDescription);
            else completion(YES, files.count, ownerRepo, nil);
        });
    }];
}

@end
