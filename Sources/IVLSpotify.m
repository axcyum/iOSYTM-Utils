#import "IVLSpotify.h"
#import "IVLLyricsService+Private.h"
#import "IVLLyricsParser.h"
#import "IVLLocalization.h"
#import <WebKit/WebKit.h>

NSNotificationName const IVLSpotifyStateDidChangeNotification = @"IVLSpotifyStateDidChangeNotification";

static NSString *const kDesktopUA = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15";
static NSString *const kLoginURL = @"https://accounts.spotify.com/login?continue=https%3A%2F%2Fopen.spotify.com%2F";

// Reports the web player's own request headers (Authorization, client-token, app version)
// and /api/token responses back to native code, so native requests match the web player's.
static NSString *const kTokenScript =
@"(function(){if(window.__ivlTok)return;window.__ivlTok=1;"
"var W=['authorization','client-token','spotify-app-version','app-platform'];"
"function post(o){try{window.webkit.messageHandlers.ivlToken.postMessage(o);}catch(e){}}"
"function walk(o,out,d){if(!o||d>14||out.length>40||typeof o!=='object')return;if(Array.isArray(o)){for(var i=0;i<o.length;i++)walk(o[i],out,d+1);return;}"
"if(typeof o.uri==='string'&&o.uri.indexOf('spotify:track:')===0&&typeof o.name==='string'){var a=[];try{((o.artists&&o.artists.items)||[]).forEach(function(x){if(x&&x.profile&&x.profile.name)a.push(x.profile.name);});}catch(e){}"
"out.push({id:o.uri.split(':')[2],name:o.name,artist:a.join(', '),ms:(o.duration&&o.duration.totalMilliseconds)||0});return;}"
"for(var k in o){walk(o[k],out,d+1);}}"
"function scan(h){try{if(!h)return;var o={};"
"if(typeof Headers!=='undefined'&&h instanceof Headers){W.forEach(function(k){var v=h.get(k);if(v)o[k]=v;});}"
"else if(Array.isArray(h)){h.forEach(function(p){var k=String(p[0]).toLowerCase();if(W.indexOf(k)>=0)o[k]=String(p[1]);});}"
"else{for(var k in h){var l=k.toLowerCase();if(W.indexOf(l)>=0)o[l]=String(h[k]);}}"
"if(Object.keys(o).length)post(o);}catch(e){}}"
"var f=window.fetch;window.fetch=function(i,o){try{scan(o&&o.headers);if(i&&i.headers)scan(i.headers);}catch(e){}"
"var p=f.apply(this,arguments);"
"try{var u=typeof i==='string'?i:((i&&i.url)||'');"
"if(u.indexOf('/api/token')>=0){p.then(function(r){return r.clone().json();}).then(function(j){if(j&&j.accessToken)post({authorization:'Bearer '+j.accessToken});}).catch(function(){});}"
"if(u.indexOf('pathfinder')>=0){p.then(function(r){return r.clone().json();}).then(function(j){var d=j&&j.data;if(!d||!d.searchV2)return;var out=[];walk(d.searchV2,out,0);if(out.length)post({search:out});}).catch(function(){});}"
"}catch(e){}"
"return p;};"
"var s=XMLHttpRequest.prototype.setRequestHeader;XMLHttpRequest.prototype.setRequestHeader=function(k,v){try{var l=String(k).toLowerCase();if(W.indexOf(l)>=0){var o={};o[l]=String(v);post(o);}}catch(e){}return s.apply(this,arguments);};"
"})();";

static NSError *IVLSpotifyError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"IVLSpotify" code:code userInfo:@{ NSLocalizedDescriptionKey: [@"Spotify: " stringByAppendingString:message] }];
}

@interface IVLSpotifyLoginViewController : UIViewController <WKNavigationDelegate>
@end

@interface IVLSpotify () <WKScriptMessageHandler>
@property (nonatomic, assign, readwrite) BOOL loggedIn;
@property (nonatomic, copy, readwrite) NSString *statusText;
- (WKWebViewConfiguration *)webConfiguration;
- (void)didLogin;
@end

/// WKUserContentController retains its handlers; break the cycle with a weak proxy.
@interface IVLWeakScriptHandler : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) id<WKScriptMessageHandler> target;
@end
@implementation IVLWeakScriptHandler
- (void)userContentController:(WKUserContentController *)c didReceiveScriptMessage:(WKScriptMessage *)m { [self.target userContentController:c didReceiveScriptMessage:m]; }
@end

@implementation IVLSpotify {
    NSString *_token;
    NSDate *_tokenExpiry;
    NSMutableDictionary<NSString *, NSString *> *_headers;   // client-token, spotify-app-version, app-platform
    void (^_searchDone)(NSArray<NSDictionary *> *_Nullable results);
    NSTimer *_searchTimer;
    NSUInteger _searchGeneration;
    WKWebView *_tokenWebView;
    NSMutableArray<void (^)(NSString *)> *_waiters;
    NSTimer *_tokenTimeout;
    NSURLSession *_session;
    WKProcessPool *_pool;
}

+ (instancetype)shared {
    static IVLSpotify *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [self new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _waiters = [NSMutableArray array];
        _headers = [NSMutableDictionary dictionary];
        _pool = [WKProcessPool new];
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest = 12;
        cfg.HTTPAdditionalHeaders = @{ @"User-Agent": kDesktopUA, @"Accept": @"application/json" };
        _session = [NSURLSession sessionWithConfiguration:cfg];
        _statusText = IVLLoc(@"spotify_logged_out");
        dispatch_async(dispatch_get_main_queue(), ^{ [self refreshLoginState]; });
    }
    return self;
}

- (WKWebViewConfiguration *)webConfiguration {
    WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
    cfg.processPool = _pool;
    cfg.websiteDataStore = [WKWebsiteDataStore defaultDataStore];
    IVLWeakScriptHandler *h = [IVLWeakScriptHandler new];
    h.target = self;
    [cfg.userContentController addScriptMessageHandler:h name:@"ivlToken"];
    [cfg.userContentController addUserScript:[[WKUserScript alloc] initWithSource:kTokenScript injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    return cfg;
}

#pragma mark - Login state

- (void)setState:(BOOL)loggedIn text:(NSString *)text {
    self.loggedIn = loggedIn;
    self.statusText = text;
    [[NSNotificationCenter defaultCenter] postNotificationName:IVLSpotifyStateDidChangeNotification object:self];
}

- (void)refreshLoginState {
    [[WKWebsiteDataStore defaultDataStore].httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        BOOL found = NO;
        for (NSHTTPCookie *c in cookies) {
            if ([c.name isEqualToString:@"sp_dc"] && [c.domain containsString:@"spotify.com"] && (!c.expiresDate || c.expiresDate.timeIntervalSinceNow > 0)) { found = YES; break; }
        }
        [self setState:found text:IVLLoc(found ? @"spotify_logged_in" : @"spotify_logged_out")];
    }];
}

- (void)didLogin {
    _token = nil;
    [self refreshLoginState];
}

- (void)logout {
    _token = nil;
    WKWebsiteDataStore *store = [WKWebsiteDataStore defaultDataStore];
    NSSet *types = [WKWebsiteDataStore allWebsiteDataTypes];
    [store fetchDataRecordsOfTypes:types completionHandler:^(NSArray<WKWebsiteDataRecord *> *records) {
        NSMutableArray *spotify = [NSMutableArray array];
        for (WKWebsiteDataRecord *r in records) if ([r.displayName containsString:@"spotify"]) [spotify addObject:r];
        [store removeDataOfTypes:types forDataRecords:spotify completionHandler:^{
            [self setState:NO text:IVLLoc(@"spotify_logged_out")];
        }];
    }];
}

- (UIViewController *)loginViewController {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[IVLSpotifyLoginViewController new]];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    return nav;
}

#pragma mark - Token (taken from the web player's own requests)

- (void)userContentController:(WKUserContentController *)c didReceiveScriptMessage:(WKScriptMessage *)message {
    NSDictionary *h = [message.body isKindOfClass:[NSDictionary class]] ? message.body : nil;
    if (!h) return;
    if ([h[@"search"] isKindOfClass:[NSArray class]]) { [self deliverSearch:h[@"search"]]; return; }
    for (NSString *k in @[@"client-token", @"spotify-app-version", @"app-platform"]) {
        NSString *v = [h[k] isKindOfClass:[NSString class]] ? h[k] : nil;
        if (v.length) _headers[k] = v;
    }
    NSString *auth = [h[@"authorization"] isKindOfClass:[NSString class]] ? h[@"authorization"] : nil;
    if (![auth.lowercaseString hasPrefix:@"bearer "]) return;
    NSString *token = [[auth substringFromIndex:7] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (token.length < 20) return;
    BOOL fresh = ![token isEqualToString:_token];
    _token = token;
    _tokenExpiry = [NSDate dateWithTimeIntervalSinceNow:45 * 60];
    if (!fresh && !_waiters.count) return;
    // give the player a moment so the client-token header is usually captured too
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_waiters.count) [self flushWaiters:self->_token];
    });
}

- (void)flushWaiters:(NSString *)token {
    [_tokenTimeout invalidate];
    _tokenTimeout = nil;
    NSArray *w = [_waiters copy];
    [_waiters removeAllObjects];
    for (void (^b)(NSString *) in w) b(token);

}

- (void)withToken:(void (^)(NSString *_Nullable token))done {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self withToken:done]; }); return; }
    if (_token && _tokenExpiry.timeIntervalSinceNow > 60) { done(_token); return; }
    [_waiters addObject:[done copy]];
    if (_tokenWebView.URL && !_tokenWebView.isLoading) {
        [_tokenWebView reload];   // a reload makes the player fetch a fresh token
    } else if (!_tokenWebView) {
        [self playerWebView];
    }
    _tokenTimeout = [NSTimer scheduledTimerWithTimeInterval:25 repeats:NO block:^(NSTimer *t) { [self flushWaiters:nil]; }];
}

/// Hidden open.spotify.com player. It lives off-screen inside the key window so its scripts
/// and React rendering run as usual (detached web views get throttled).
- (WKWebView *)playerWebView {
    if (!_tokenWebView) {
        _tokenWebView = [[WKWebView alloc] initWithFrame:CGRectMake(-2000, 0, 1024, 768) configuration:[self webConfiguration]];
        _tokenWebView.customUserAgent = kDesktopUA;
        _tokenWebView.userInteractionEnabled = NO;
        _tokenWebView.alpha = 0.01;
        [_tokenWebView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://open.spotify.com/"]]];
    }
    if (!_tokenWebView.window) {
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            UIWindow *w = ((UIWindowScene *)sc).windows.firstObject;
            if (w) { [w insertSubview:_tokenWebView atIndex:0]; break; }
        }
    }
    return _tokenWebView;
}

#pragma mark - Search (done by the web player itself; api.spotify.com rate-limits web tokens with 429)

- (void)deliverSearch:(NSArray *)raw {
    if (!_searchDone) return;
    NSMutableArray *cands = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSDictionary *t in raw) {
        if (![t isKindOfClass:[NSDictionary class]] || ![t[@"id"] isKindOfClass:[NSString class]] || [seen containsObject:t[@"id"]]) continue;
        [seen addObject:t[@"id"]];
        id msObj = t[@"ms"];
        double sec = [msObj respondsToSelector:@selector(doubleValue)] ? ([msObj doubleValue] / 1000.0) : 0.0;
        [cands addObject:@{ @"id": t[@"id"], @"title": [t[@"name"] description] ?: @"", @"artist": [t[@"artist"] description] ?: @"",
                            @"duration": @(sec) }];
    }
    if (!cands.count) return;
    void (^done)(NSArray *) = _searchDone;
    _searchDone = nil;
    [_searchTimer invalidate];
    done(cands);
}

- (void)webSearch:(NSString *)query completion:(void (^)(NSArray<NSDictionary *> *_Nullable results))completion {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self webSearch:query completion:completion]; }); return; }
    if (_searchDone) { void (^old)(NSArray *) = _searchDone; _searchDone = nil; old(nil); }
    _searchDone = [completion copy];
    NSUInteger gen = ++_searchGeneration;
    WKWebView *web = [self playerWebView];
    NSString *path = [@"/search/" stringByAppendingString:[query stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet] ?: @""];
    // SPA navigation first (fast); a full page load if the player did not react
    [web callAsyncJavaScript:@"history.pushState({},'',p);dispatchEvent(new PopStateEvent('popstate',{state:{}}));"
                   arguments:@{ @"p": path } inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:nil];
    [_searchTimer invalidate];
    _searchTimer = [NSTimer scheduledTimerWithTimeInterval:6 repeats:NO block:^(NSTimer *t) {
        if (gen != self->_searchGeneration || !self->_searchDone) return;
        [web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:[@"https://open.spotify.com" stringByAppendingString:path]]]];
        self->_searchTimer = [NSTimer scheduledTimerWithTimeInterval:14 repeats:NO block:^(NSTimer *t2) {
            if (gen != self->_searchGeneration || !self->_searchDone) return;
            void (^done)(NSArray *) = self->_searchDone;
            self->_searchDone = nil;
            done(nil);
        }];
    }];
}

/// Lyrics request made from inside the player page (same origin and headers as the player).
- (void)pageGet:(NSString *)url token:(NSString *)token completion:(void (^)(id json, NSInteger status))completion {
    WKWebView *web = [self playerWebView];
    NSString *body = @"const h={'authorization':'Bearer '+auth,'app-platform':'WebPlayer'};if(ct)h['client-token']=ct;"
                      "const r=await fetch(url,{headers:h});if(!r.ok)return JSON.stringify({status:r.status});"
                      "return JSON.stringify({status:200,body:await r.json()});";
    [web callAsyncJavaScript:body arguments:@{ @"url": url, @"auth": token, @"ct": _headers[@"client-token"] ?: @"" }
                     inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:^(id result, NSError *error) {
        NSDictionary *d = [result isKindOfClass:[NSString class]]
            ? [NSJSONSerialization JSONObjectWithData:[result dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
        completion(d[@"body"], [d[@"status"] integerValue]);
    }];
}

#pragma mark - API

- (void)get:(NSString *)url token:(NSString *)token completion:(void (^)(id json, NSInteger status))completion {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"WebPlayer" forHTTPHeaderField:@"app-platform"];
    NSDictionary *extra = [_headers copy];
    for (NSString *k in extra) [req setValue:extra[k] forHTTPHeaderField:k];
    [req setValue:@"https://open.spotify.com" forHTTPHeaderField:@"Origin"];
    [req setValue:@"https://open.spotify.com/" forHTTPHeaderField:@"Referer"];
    [[_session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        NSInteger status = [r isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)r).statusCode : 0;
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        completion(json, status);
    }] resume];
}

static NSString *IVLEnc(NSString *s) {
    NSMutableCharacterSet *ok = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [ok addCharactersInString:@"-._~"];
    return [s stringByAddingPercentEncodingWithAllowedCharacters:ok] ?: @"";
}

+ (IVLLyrics *)parseColorLyrics:(NSDictionary *)json durationMs:(NSInteger)durMs {
    NSDictionary *l = [json isKindOfClass:[NSDictionary class]] ? json[@"lyrics"] : nil;
    NSArray *raw = [l isKindOfClass:[NSDictionary class]] ? l[@"lines"] : nil;
    if (![raw isKindOfClass:[NSArray class]] || !raw.count) return nil;
    NSString *sync = [[l[@"syncType"] description] uppercaseString];
    NSMutableArray<IVLLyricLine *> *lines = [NSMutableArray array];
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (NSDictionary *d in raw) {
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        NSString *text = [[d[@"words"] description] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
        if ([text isEqualToString:@"♪"]) text = @"";
        IVLLyricLine *line = [IVLLyricLine new];
        line.startMs = [d[@"startTimeMs"] integerValue];
        line.endMs = [d[@"endTimeMs"] integerValue];
        line.text = text;
        // SYLLABLE_SYNCED: syllables carry start times and character counts
        NSArray *syl = d[@"syllables"];
        if ([sync isEqualToString:@"SYLLABLE_SYNCED"] && [syl isKindOfClass:[NSArray class]] && syl.count && text.length) {
            NSMutableArray<IVLWord *> *words = [NSMutableArray array];
            NSUInteger pos = 0;
            for (NSDictionary *s in syl) {
                if (![s isKindOfClass:[NSDictionary class]]) continue;
                NSUInteger n = [s[@"numChars"] unsignedIntegerValue];
                if (!n || pos + n > text.length) break;
                NSInteger st = [s[@"startTimeMs"] integerValue], en = [s[@"endTimeMs"] integerValue];
                [words addObject:[IVLWord wordWithText:[text substringWithRange:NSMakeRange(pos, n)] start:st end:en]];
                pos += n;
            }
            if (pos < text.length && words.count) words.lastObject.text = [words.lastObject.text stringByAppendingString:[text substringFromIndex:pos]];
            if (words.count) { line.text = [IVLLyricsParser normalizeWords:words]; line.words = words; }
        }
        [lines addObject:line];
        if (text.length) [texts addObject:text];
    }
    if ([sync isEqualToString:@"UNSYNCED"]) return [IVLLyricsParser parsePlain:[texts componentsJoinedByString:@"\n"]];
    return [IVLLyricsParser lyricsWithTimedLines:lines durationMs:durMs explicitEnds:NO];
}

- (void)lyricsForTrack:(IVLTrack *)track completion:(IVLLyricsCompletion)completion {
    if (!self.loggedIn) { completion(nil, IVLSpotifyError(401, IVLLoc(@"spotify_logged_out"))); return; }
    [self lyricsForTrack:track retry:YES completion:completion];
}

- (void)lyricsForTrack:(IVLTrack *)track retry:(BOOL)retry completion:(IVLLyricsCompletion)completion {
    [self withToken:^(NSString *token) {
        if (!token) { completion(nil, IVLSpotifyError(408, @"token timeout")); return; }
        NSString *title = [IVLLyricsService cleanTitle:track.title];
        NSString *artist = [IVLLyricsService cleanArtist:track.artist];
        NSString *q = artist.length ? [NSString stringWithFormat:@"%@ %@", title, artist] : title;
        [self webSearch:q completion:^(NSArray<NSDictionary *> *cands) {
            if (!cands) { completion(nil, IVLSpotifyError(504, @"search timeout")); return; }
            NSDictionary *best = IVLBestCandidate(cands, track);
            if (!best) {
                NSString *first = cands.count ? [NSString stringWithFormat:@" (top: %@ / %@)", cands[0][@"title"], cands[0][@"artist"]] : @"";
                completion(nil, IVLSpotifyError(404, [NSString stringWithFormat:@"no matching track in %lu results%@", (unsigned long)cands.count, first]));
                return;
            }
            NSString *url = [NSString stringWithFormat:@"https://spclient.wg.spotify.com/color-lyrics/v2/track/%@?format=json&vocalRemoval=false&market=from_token", best[@"id"]];
            void (^finish)(id, NSInteger) = ^(id lj, NSInteger ls) {
                IVLLyrics *ly = ls == 200 ? [IVLSpotify parseColorLyrics:lj durationMs:(NSInteger)(track.duration * 1000)] : nil;
                ly.source = @"Spotify";
                if (ly) { completion(ly, nil); return; }
                NSString *why = ls == 404 ? [NSString stringWithFormat:@"no lyrics for %@", best[@"title"]] : [NSString stringWithFormat:@"lyrics HTTP %ld", (long)ls];
                completion(nil, IVLSpotifyError(ls == 404 ? 404 : (ls ?: 503), why));
            };
            [self get:url token:token completion:^(id lj, NSInteger ls) {
                if (ls == 200 || ls == 404) { finish(lj, ls); return; }
                dispatch_async(dispatch_get_main_queue(), ^{ [self pageGet:url token:token completion:finish]; });
            }];
        }];
    }];
}

- (void)resolveTokenAndTrackIDForTrack:(IVLTrack *)track
                            completion:(void (^)(NSString *_Nullable token, NSString *_Nullable trackID, NSError *_Nullable error))completion {
    if (!self.loggedIn) {
        completion(nil, nil, IVLSpotifyError(401, @"Spotify login required"));
        return;
    }
    [self withToken:^(NSString *token) {
        if (!token.length) { completion(nil, nil, IVLSpotifyError(408, @"token timeout")); return; }
        NSString *title = [IVLLyricsService cleanTitle:track.title];
        NSString *artist = [IVLLyricsService cleanArtist:track.artist];
        NSString *q = artist.length ? [NSString stringWithFormat:@"%@ %@", title, artist] : title;
        [self webSearch:q completion:^(NSArray<NSDictionary *> *cands) {
            NSDictionary *best = cands.count ? IVLBestCandidate(cands, track) : nil;
            NSString *tid = [best[@"id"] isKindOfClass:[NSString class]] ? best[@"id"] : nil;
            if (!tid.length) {
                completion(token, nil, IVLSpotifyError(404, @"no matching Spotify track"));
                return;
            }
            completion(token, tid, nil);
        }];
    }];
}

@end

#pragma mark - Login screen

@implementation IVLSpotifyLoginViewController {
    WKWebView *_web;
    BOOL _done;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = IVLLoc(@"spotify_login");
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    _web = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:[[IVLSpotify shared] webConfiguration]];
    _web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _web.navigationDelegate = self;
    [self.view addSubview:_web];
    [_web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:kLoginURL]]];
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if (_done || ![webView.URL.host hasSuffix:@"open.spotify.com"]) return;
    [[WKWebsiteDataStore defaultDataStore].httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        for (NSHTTPCookie *c in cookies) {
            if ([c.name isEqualToString:@"sp_dc"] && [c.domain containsString:@"spotify.com"]) {
                self->_done = YES;
                [[IVLSpotify shared] didLogin];
                [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
                [self close];
                return;
            }
        }
    }];
}

@end
