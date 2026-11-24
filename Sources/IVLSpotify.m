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
"function scan(h){try{if(!h)return;var o={};"
"if(typeof Headers!=='undefined'&&h instanceof Headers){W.forEach(function(k){var v=h.get(k);if(v)o[k]=v;});}"
"else if(Array.isArray(h)){h.forEach(function(p){var k=String(p[0]).toLowerCase();if(W.indexOf(k)>=0)o[k]=String(p[1]);});}"
"else{for(var k in h){var l=k.toLowerCase();if(W.indexOf(l)>=0)o[l]=String(h[k]);}}"
"if(Object.keys(o).length)post(o);}catch(e){}}"
"var f=window.fetch;window.fetch=function(i,o){try{scan(o&&o.headers);if(i&&i.headers)scan(i.headers);}catch(e){}"
"var p=f.apply(this,arguments);"
"try{var u=typeof i==='string'?i:((i&&i.url)||'');if(u.indexOf('/api/token')>=0){p.then(function(r){return r.clone().json();}).then(function(j){if(j&&j.accessToken)post({authorization:'Bearer '+j.accessToken});}).catch(function(){});}}catch(e){}"
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
    if (_tokenWebView) {
        WKWebView *web = _tokenWebView;
        _tokenWebView = nil;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [web stopLoading];
            [web removeFromSuperview];
        });
    }
}

- (void)withToken:(void (^)(NSString *_Nullable token))done {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self withToken:done]; }); return; }
    if (_token && _tokenExpiry.timeIntervalSinceNow > 60) { done(_token); return; }
    [_waiters addObject:[done copy]];
    if (_tokenWebView) return;
    _tokenWebView = [[WKWebView alloc] initWithFrame:CGRectMake(0, 0, 400, 400) configuration:[self webConfiguration]];
    _tokenWebView.customUserAgent = kDesktopUA;
    [_tokenWebView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://open.spotify.com/"]]];
    _tokenTimeout = [NSTimer scheduledTimerWithTimeInterval:25 repeats:NO block:^(NSTimer *t) { [self flushWaiters:nil]; }];
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
        NSString *search = [NSString stringWithFormat:@"https://api.spotify.com/v1/search?type=track&limit=20&q=%@", IVLEnc(q)];
        [self get:search token:token completion:^(id json, NSInteger status) {
            if (status == 401 && retry) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self->_token = nil;
                    [self lyricsForTrack:track retry:NO completion:completion];
                });
                return;
            }
            if (status != 200) { completion(nil, IVLSpotifyError(status ?: 503, [NSString stringWithFormat:@"search HTTP %ld", (long)status])); return; }
            NSArray *items = [json isKindOfClass:[NSDictionary class]] ? json[@"tracks"][@"items"] : nil;
            NSMutableArray *cands = [NSMutableArray array];
            for (NSDictionary *it in [items isKindOfClass:[NSArray class]] ? items : @[]) {
                if (![it isKindOfClass:[NSDictionary class]] || ![it[@"id"] isKindOfClass:[NSString class]]) continue;
                NSMutableArray *names = [NSMutableArray array];
                for (NSDictionary *a in it[@"artists"]) if ([a isKindOfClass:[NSDictionary class]] && a[@"name"]) [names addObject:a[@"name"]];
                [cands addObject:@{ @"id": it[@"id"], @"title": [it[@"name"] description] ?: @"",
                                    @"artist": [names componentsJoinedByString:@", "], @"duration": @([it[@"duration_ms"] doubleValue] / 1000.0) }];
            }
            NSDictionary *best = IVLBestCandidate(cands, track);
            if (!best) {
                NSString *first = cands.count ? [NSString stringWithFormat:@" (top: %@ / %@)", cands[0][@"title"], cands[0][@"artist"]] : @"";
                completion(nil, IVLSpotifyError(404, [NSString stringWithFormat:@"no matching track in %lu results%@", (unsigned long)cands.count, first]));
                return;
            }
            NSString *url = [NSString stringWithFormat:@"https://spclient.wg.spotify.com/color-lyrics/v2/track/%@?format=json&vocalRemoval=false&market=from_token", best[@"id"]];
            [self get:url token:token completion:^(id lj, NSInteger ls) {
                IVLLyrics *ly = ls == 200 ? [IVLSpotify parseColorLyrics:lj durationMs:(NSInteger)(track.duration * 1000)] : nil;
                ly.source = @"Spotify";
                if (ly) { completion(ly, nil); return; }
                NSString *why = ls == 404 ? [NSString stringWithFormat:@"no lyrics for %@", best[@"title"]] : [NSString stringWithFormat:@"lyrics HTTP %ld", (long)ls];
                completion(nil, IVLSpotifyError(ls == 404 ? 404 : (ls ?: 503), why));
            }];
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
