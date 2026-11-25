// Convenience features modelled on SimpMusic (maxrave-dev/SimpMusic): sleep timer, listening
// statistics, lyrics themes, sharing lyrics as an image. No ad blocking / downloads / premium.

#import "IVLExtras.h"
#import "IVLPlaybackManager.h"
#import "IVLRemoteControl.h"
#import "IVLSettings.h"
#import "IVLLocalization.h"
#import <CoreImage/CoreImage.h>

NSNotificationName const IVLSleepTimerDidChangeNotification = @"IVLSleepTimerDidChangeNotification";

#pragma mark - Sleep timer

@interface IVLSleepTimer ()
@property (nonatomic, readwrite) BOOL active;
@property (nonatomic, readwrite) BOOL endOfTrack;
@property (nonatomic, strong, readwrite) NSDate *fireDate;
@end

@implementation IVLSleepTimer {
    NSTimer *_timer;
    NSString *_trackID;
}

+ (instancetype)shared {
    static IVLSleepTimer *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [self new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(trackChanged) name:IVLTrackDidChangeNotification object:nil];
    }
    return self;
}

- (void)changed { [[NSNotificationCenter defaultCenter] postNotificationName:IVLSleepTimerDidChangeNotification object:self]; }

- (void)startMinutes:(NSInteger)minutes {
    [self cancelSilently];
    self.active = YES;
    self.fireDate = [NSDate dateWithTimeIntervalSinceNow:minutes * 60];
    _timer = [NSTimer scheduledTimerWithTimeInterval:minutes * 60 target:self selector:@selector(fire) userInfo:nil repeats:NO];
    _timer.tolerance = 1;
    [self changed];
}

- (void)startEndOfTrack {
    [self cancelSilently];
    self.active = YES;
    self.endOfTrack = YES;
    _trackID = [IVLPlaybackManager shared].track.videoID;
    // watch the position: pause just before the end so the next song never starts
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(checkEnd) userInfo:nil repeats:YES];
    [self changed];
}

- (void)checkEnd {
    IVLPlaybackManager *m = [IVLPlaybackManager shared];
    double dur = m.track.duration;
    if (dur > 0 && [m rawTimeMs] / 1000.0 >= dur - 1.2) [self fire];
}

- (void)trackChanged {
    if (self.active && self.endOfTrack && _trackID && ![_trackID isEqualToString:[IVLPlaybackManager shared].track.videoID]) [self fire];
}

- (void)fire {
    [IVLRemoteControl pause];
    [self cancel];
}

- (void)cancelSilently {
    [_timer invalidate];
    _timer = nil;
    self.active = NO;
    self.endOfTrack = NO;
    self.fireDate = nil;
    _trackID = nil;
}

- (void)cancel { [self cancelSilently]; [self changed]; }

- (NSString *)statusText {
    if (!self.active) return IVLLoc(@"off");
    if (self.endOfTrack) return IVLLoc(@"sleep_end_of_track");
    NSInteger left = (NSInteger)MAX(0, ceil(self.fireDate.timeIntervalSinceNow / 60.0));
    return [NSString stringWithFormat:IVLLoc(@"sleep_left_fmt"), (long)left];
}

@end

@implementation IVLSleepTimerViewController {
    NSTimer *_refresh;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = IVLLoc(@"sleep_timer");
    [[NSNotificationCenter defaultCenter] addObserver:self.tableView selector:@selector(reloadData) name:IVLSleepTimerDidChangeNotification object:nil];
    __weak UITableView *tv = self.tableView;
    _refresh = [NSTimer scheduledTimerWithTimeInterval:20 repeats:YES block:^(NSTimer *t) { [tv reloadData]; }];
}

- (void)dealloc { [_refresh invalidate]; [[NSNotificationCenter defaultCenter] removeObserver:self.tableView]; }

- (NSArray<NSNumber *> *)minutes { return @[@5, @10, @15, @30, @45, @60, @90]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)s { return s == 0 ? 1 : (s == 1 ? (NSInteger)[self minutes].count + 1 : 1); }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)s { return s == 2 ? IVLLoc(@"footer_sleep") : nil; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    IVLSleepTimer *t = [IVLSleepTimer shared];
    if (ip.section == 0) {
        c.textLabel.text = IVLLoc(@"status");
        c.detailTextLabel.text = [t statusText];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (ip.section == 1) {
        if (ip.row < (NSInteger)[self minutes].count) {
            c.textLabel.text = [NSString stringWithFormat:IVLLoc(@"sleep_minutes_fmt"), (long)[self minutes][ip.row].integerValue];
        } else {
            c.textLabel.text = IVLLoc(@"sleep_end_of_track");
            if (t.endOfTrack) c.accessoryType = UITableViewCellAccessoryCheckmark;
        }
    } else {
        c.textLabel.text = IVLLoc(@"sleep_cancel");
        c.textLabel.textColor = t.active ? UIColor.systemRedColor : UIColor.secondaryLabelColor;
    }
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    IVLSleepTimer *t = [IVLSleepTimer shared];
    if (ip.section == 1) {
        if (ip.row < (NSInteger)[self minutes].count) [t startMinutes:[self minutes][ip.row].integerValue];
        else [t startEndOfTrack];
        [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
    } else if (ip.section == 2) {
        [t cancel];
    }
}

@end

#pragma mark - Statistics

static NSInteger _dirtyTicks;

@implementation IVLStats {
    NSMutableArray<NSDictionary *> *_plays;   // {t: epoch s, title, artist, sec: listened seconds}
    NSString *_currentKey;
    double _listened;
    NSDictionary *_current;
    NSTimer *_timer;
    BOOL _dirty;
}

+ (instancetype)shared {
    static IVLStats *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [self new]; });
    return s;
}

- (NSString *)path {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [base stringByAppendingPathComponent:@"ivLyricsYTM/stats.json"];
}

- (void)start {
    if (_timer) return;
    NSData *d = [NSData dataWithContentsOfFile:[self path]];
    id json = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    _plays = [json isKindOfClass:[NSArray class]] ? [json mutableCopy] : [NSMutableArray array];
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    _timer.tolerance = 0.3;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(flush) name:UIApplicationDidEnterBackgroundNotification object:nil];
}

- (void)tick {
    if (![IVLSettings boolForKey:IVLKeyStatsEnabled]) return;
    IVLTrack *t = [IVLPlaybackManager shared].track;
    if (!t.title.length) return;
    NSString *key = t.videoID ?: t.title;
    if (![key isEqualToString:_currentKey]) {
        [self commit];
        _currentKey = key;
        _listened = 0;
        _current = @{ @"title": t.title, @"artist": t.artist ?: @"", @"t": @((long long)NSDate.date.timeIntervalSince1970) };
    }
    [[IVLPlaybackManager shared] rawTimeMs];   // refreshes the playing flag
    if ([IVLRemoteControl isPlaying]) _listened += 1.0;
    if (++_dirtyTicks >= 60) [self flush];
}

/// A play counts after 30 s (same idea as scrobblers).
- (void)commit {
    if (_current && _listened >= 30) {
        NSMutableDictionary *p = [_current mutableCopy];
        p[@"sec"] = @((NSInteger)_listened);
        [_plays addObject:p];
        if (_plays.count > 20000) [_plays removeObjectsInRange:NSMakeRange(0, _plays.count - 20000)];
        _dirty = YES;
    }
    _current = nil;
}

- (void)flush {
    _dirtyTicks = 0;
    NSMutableArray *all = [_plays mutableCopy];
    if (_current && _listened >= 30) {   // include the song in progress without committing it
        NSMutableDictionary *p = [_current mutableCopy];
        p[@"sec"] = @((NSInteger)_listened);
        [all addObject:p];
    }
    if (!_dirty && all.count == _plays.count) return;
    _dirty = NO;
    [[NSFileManager defaultManager] createDirectoryAtPath:[[self path] stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSJSONSerialization dataWithJSONObject:_plays options:0 error:nil] writeToFile:[self path] atomically:YES];
}

- (void)reset {
    [_plays removeAllObjects];
    _current = nil;
    _listened = 0;
    _dirty = YES;
    [self flush];
}

- (NSDictionary *)summaryForDays:(NSInteger)days {
    double since = days > 0 ? NSDate.date.timeIntervalSince1970 - days * 86400.0 : 0;
    NSMutableArray *plays = [NSMutableArray array];
    for (NSDictionary *p in _plays) if ([p[@"t"] doubleValue] >= since) [plays addObject:p];
    if (_current && _listened >= 30) { NSMutableDictionary *p = [_current mutableCopy]; p[@"sec"] = @((NSInteger)_listened); [plays addObject:p]; }

    NSMutableDictionary<NSString *, NSMutableDictionary *> *songs = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *artists = [NSMutableDictionary dictionary];
    NSMutableArray<NSNumber *> *hours = [NSMutableArray array];
    for (int i = 0; i < 24; i++) [hours addObject:@0];
    double total = 0;
    NSCalendar *cal = NSCalendar.currentCalendar;
    for (NSDictionary *p in plays) {
        double sec = [p[@"sec"] doubleValue];
        total += sec;
        NSString *sk = [NSString stringWithFormat:@"%@\n%@", p[@"title"], p[@"artist"]];
        NSMutableDictionary *s = songs[sk] ?: (songs[sk] = [@{ @"title": p[@"title"] ?: @"", @"artist": p[@"artist"] ?: @"", @"count": @0, @"sec": @0 } mutableCopy]);
        s[@"count"] = @([s[@"count"] integerValue] + 1); s[@"sec"] = @([s[@"sec"] doubleValue] + sec);
        NSString *ak = [p[@"artist"] length] ? p[@"artist"] : @"?";
        NSMutableDictionary *a = artists[ak] ?: (artists[ak] = [@{ @"title": ak, @"count": @0, @"sec": @0 } mutableCopy]);
        a[@"count"] = @([a[@"count"] integerValue] + 1); a[@"sec"] = @([a[@"sec"] doubleValue] + sec);
        NSInteger h = [cal component:NSCalendarUnitHour fromDate:[NSDate dateWithTimeIntervalSince1970:[p[@"t"] doubleValue]]];
        hours[h] = @(hours[h].doubleValue + sec);
    }
    NSSortDescriptor *byCount = [NSSortDescriptor sortDescriptorWithKey:@"count" ascending:NO];
    NSSortDescriptor *bySec = [NSSortDescriptor sortDescriptorWithKey:@"sec" ascending:NO];
    NSArray *topSongs = [songs.allValues sortedArrayUsingDescriptors:@[byCount, bySec]];
    NSArray *topArtists = [artists.allValues sortedArrayUsingDescriptors:@[bySec, byCount]];
    return @{ @"plays": @(plays.count), @"seconds": @(total), @"songs": @(songs.count), @"artists": @(artists.count),
              @"topSongs": [topSongs subarrayWithRange:NSMakeRange(0, MIN(10, topSongs.count))],
              @"topArtists": [topArtists subarrayWithRange:NSMakeRange(0, MIN(10, topArtists.count))],
              @"hours": hours };
}

@end

@implementation IVLStatsViewController {
    NSDictionary *_sum;
    UISegmentedControl *_range;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = IVLLoc(@"stats");
    _range = [[UISegmentedControl alloc] initWithItems:@[IVLLoc(@"stats_7d"), IVLLoc(@"stats_30d"), IVLLoc(@"stats_all")]];
    _range.selectedSegmentIndex = 1;
    [_range addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = _range;
    [self reload];
}

- (void)reload {
    NSInteger days = _range.selectedSegmentIndex == 0 ? 7 : (_range.selectedSegmentIndex == 1 ? 30 : 0);
    _sum = [[IVLStats shared] summaryForDays:days];
    [self.tableView reloadData];
}

static NSString *IVLDuration(double sec) {
    long m = (long)(sec / 60);
    return m >= 60 ? [NSString stringWithFormat:@"%ldh %02ldm", m / 60, m % 60] : [NSString stringWithFormat:@"%ldm", m];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 6; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return 1;
    if (s == 1) return 4;
    if (s == 2) return 1;
    if (s == 3) return MAX(1, (NSInteger)[_sum[@"topSongs"] count]);
    if (s == 4) return MAX(1, (NSInteger)[_sum[@"topArtists"] count]);
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)s {
    return @[@"", IVLLoc(@"stats_overview"), IVLLoc(@"stats_clock"), IVLLoc(@"stats_top_songs"), IVLLoc(@"stats_top_artists"), @""][s];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)s { return s == 5 ? IVLLoc(@"footer_stats") : nil; }

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)ip { return ip.section == 2 ? 120 : UITableViewAutomaticDimension; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:(ip.section >= 3 && ip.section <= 4) ? UITableViewCellStyleSubtitle : UITableViewCellStyleValue1 reuseIdentifier:nil];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    if (ip.section == 0) {
        c.textLabel.text = IVLLoc(@"stats_record");
        UISwitch *sw = [UISwitch new];
        sw.on = [IVLSettings boolForKey:IVLKeyStatsEnabled];
        [sw addAction:[UIAction actionWithHandler:^(UIAction *a) {
            [IVLSettings setBool:((UISwitch *)a.sender).on forKey:IVLKeyStatsEnabled];
        }] forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
    } else if (ip.section == 1) {
        NSArray *rows = @[@[IVLLoc(@"stats_time"), IVLDuration([_sum[@"seconds"] doubleValue])],
                          @[IVLLoc(@"stats_plays"), [_sum[@"plays"] description]],
                          @[IVLLoc(@"stats_songs"), [_sum[@"songs"] description]],
                          @[IVLLoc(@"stats_artists"), [_sum[@"artists"] description]]];
        c.textLabel.text = rows[ip.row][0];
        c.detailTextLabel.text = rows[ip.row][1];
    } else if (ip.section == 2) {
        // listening clock: 24 bars
        NSArray<NSNumber *> *hours = _sum[@"hours"];
        double maxv = 1;
        for (NSNumber *h in hours) maxv = MAX(maxv, h.doubleValue);
        UIView *chart = [[UIView alloc] initWithFrame:CGRectMake(16, 10, tableView.bounds.size.width - 64, 100)];
        CGFloat w = chart.bounds.size.width / 24.0;
        for (NSInteger i = 0; i < 24; i++) {
            CGFloat h = MAX(2, 80 * hours[i].doubleValue / maxv);
            UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(i * w + 1, 80 - h, w - 2, h)];
            bar.backgroundColor = [IVLTheme accentColor];
            bar.layer.cornerRadius = 2;
            [chart addSubview:bar];
            if (i % 6 == 0) {
                UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(i * w, 84, 30, 14)];
                l.text = @(i).stringValue;
                l.font = [UIFont systemFontOfSize:10];
                l.textColor = UIColor.secondaryLabelColor;
                [chart addSubview:l];
            }
        }
        [c.contentView addSubview:chart];
    } else if (ip.section == 3 || ip.section == 4) {
        NSArray *list = _sum[ip.section == 3 ? @"topSongs" : @"topArtists"];
        if (!list.count) { c.textLabel.text = IVLLoc(@"stats_empty"); c.textLabel.textColor = UIColor.secondaryLabelColor; return c; }
        NSDictionary *e = list[ip.row];
        c.textLabel.text = [NSString stringWithFormat:@"%ld. %@", (long)ip.row + 1, e[@"title"]];
        NSString *plays = [NSString stringWithFormat:IVLLoc(@"stats_plays_fmt"), (long)[e[@"count"] integerValue]];
        c.detailTextLabel.text = ip.section == 3 ? [NSString stringWithFormat:@"%@ · %@", e[@"artist"], plays]
                                                 : [NSString stringWithFormat:@"%@ · %@", IVLDuration([e[@"sec"] doubleValue]), plays];
    } else {
        c.textLabel.text = IVLLoc(@"stats_reset");
        c.textLabel.textColor = UIColor.systemRedColor;
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != 5) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:IVLLoc(@"stats_reset") message:IVLLoc(@"stats_reset_confirm") preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:IVLLoc(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:IVLLoc(@"stats_reset") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        [[IVLStats shared] reset];
        [self reload];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

@end

#pragma mark - Theme

@implementation IVLTheme

+ (NSInteger)style { return [IVLSettings integerForKey:IVLKeyBackground]; }

+ (NSArray<NSArray *> *)presetColors {
    return @[@[@"White", @"FFFFFF"], @[@"Red", @"FF5A5F"], @[@"Pink", @"FF7EB6"], @[@"Orange", @"FF9F43"], @[@"Yellow", @"FFD84D"],
             @[@"Green", @"4CD97B"], @[@"Mint", @"5DE0C8"], @[@"Blue", @"5AA9FF"], @[@"Purple", @"A78BFA"]];
}

+ (UIColor *)colorFromHex:(NSString *)hex {
    unsigned int v = 0;
    [[NSScanner scannerWithString:[hex stringByReplacingOccurrencesOfString:@"#" withString:@""]] scanHexInt:&v];
    return [UIColor colorWithRed:((v >> 16) & 0xFF) / 255.0 green:((v >> 8) & 0xFF) / 255.0 blue:(v & 0xFF) / 255.0 alpha:1];
}

+ (UIColor *)accentColor {
    NSString *hex = [IVLSettings objectForKey:IVLKeyAccentColor];
    return [hex isKindOfClass:[NSString class]] && hex.length ? [self colorFromHex:hex] : UIColor.whiteColor;
}

+ (UIColor *)customBackgroundColor {
    NSString *hex = [IVLSettings objectForKey:IVLKeyBackgroundColor];
    return [hex isKindOfClass:[NSString class]] && hex.length ? [self colorFromHex:hex] : [UIColor colorWithRed:0.07 green:0.07 blue:0.08 alpha:1];
}

/// Average colours of the upper and lower halves, darkened enough for white text.
+ (void)dominantColorsOfImage:(UIImage *)image completion:(void (^)(UIColor *, UIColor *))completion {
    if (!image.CGImage && !image.CIImage) { completion(UIColor.darkGrayColor, UIColor.blackColor); return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        static CIContext *ctx;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ ctx = [CIContext contextWithOptions:@{ kCIContextWorkingColorSpace: [NSNull null] }]; });
        CIImage *ci = image.CIImage ?: [CIImage imageWithCGImage:image.CGImage];
        CGRect e = ci.extent;
        UIColor *(^avg)(CGRect) = ^UIColor *(CGRect r) {
            CIFilter *f = [CIFilter filterWithName:@"CIAreaAverage" withInputParameters:@{ kCIInputImageKey: ci, kCIInputExtentKey: [CIVector vectorWithCGRect:r] }];
            uint8_t px[4] = {0};
            [ctx render:f.outputImage toBitmap:px rowBytes:4 bounds:CGRectMake(0, 0, 1, 1) format:kCIFormatRGBA8 colorSpace:nil];
            CGFloat h, s, b, a;
            UIColor *c = [UIColor colorWithRed:px[0] / 255.0 green:px[1] / 255.0 blue:px[2] / 255.0 alpha:1];
            [c getHue:&h saturation:&s brightness:&b alpha:&a];
            return [UIColor colorWithHue:h saturation:MIN(1, s * 1.15) brightness:MIN(b, 0.55) alpha:1];
        };
        // CoreImage origin is bottom-left
        UIColor *top = avg(CGRectMake(e.origin.x, e.origin.y + e.size.height / 2, e.size.width, e.size.height / 2));
        UIColor *bottom = avg(CGRectMake(e.origin.x, e.origin.y, e.size.width, e.size.height / 2));
        CGFloat h, s, b, a;
        [bottom getHue:&h saturation:&s brightness:&b alpha:&a];
        bottom = [UIColor colorWithHue:h saturation:s brightness:b * 0.55 alpha:1];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(top, bottom); });
    });
}

@end

#pragma mark - Share image

UIImage *IVLLyricsShareImage(NSArray<NSString *> *lines, NSString *translation, NSString *title, NSString *artist, UIImage *artwork) {
    const CGFloat W = 1080, pad = 90;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1; fmt.opaque = YES;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(W, W) format:fmt] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGRect r = CGRectMake(0, 0, W, W);
        [[UIColor colorWithRed:0.08 green:0.08 blue:0.1 alpha:1] setFill];
        UIRectFill(r);
        if (artwork) {
            CIImage *ci = [CIImage imageWithCGImage:artwork.CGImage];
            if (ci) {
                CIImage *blur = [[ci imageByClampingToExtent] imageByApplyingGaussianBlurWithSigma:40];
                CIContext *cc = [CIContext context];
                CGImageRef cg = [cc createCGImage:blur fromRect:ci.extent];
                if (cg) {
                    [[UIImage imageWithCGImage:cg] drawInRect:r];
                    CGImageRelease(cg);
                }
            }
            [[UIColor colorWithWhite:0 alpha:0.45] setFill];
            UIRectFillUsingBlendMode(r, kCGBlendModeNormal);
            // small cover + title
            CGRect cover = CGRectMake(pad, W - pad - 120, 120, 120);
            UIBezierPath *clip = [UIBezierPath bezierPathWithRoundedRect:cover cornerRadius:16];
            CGContextSaveGState(ctx.CGContext);
            [clip addClip];
            [artwork drawInRect:cover];
            CGContextRestoreGState(ctx.CGContext);
        }
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
        ps.lineSpacing = 10;
        NSDictionary *big = @{ NSFontAttributeName: [UIFont systemFontOfSize:62 weight:UIFontWeightBold], NSForegroundColorAttributeName: UIColor.whiteColor, NSParagraphStyleAttributeName: ps };
        NSDictionary *small = @{ NSFontAttributeName: [UIFont systemFontOfSize:38 weight:UIFontWeightSemibold], NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.75], NSParagraphStyleAttributeName: ps };
        NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:[lines componentsJoinedByString:@"\n"] attributes:big];
        if (translation.length) [text appendAttributedString:[[NSAttributedString alloc] initWithString:[@"\n\n" stringByAppendingString:translation] attributes:small]];
        CGRect box = CGRectMake(pad, pad, W - pad * 2, W - pad * 2 - 170);
        CGRect used = [text boundingRectWithSize:box.size options:NSStringDrawingUsesLineFragmentOrigin context:nil];
        [text drawWithRect:CGRectMake(pad, pad + MAX(0, (box.size.height - used.size.height) / 2), box.size.width, box.size.height)
                   options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine context:nil];
        CGFloat x = artwork ? pad + 150 : pad;
        [title drawInRect:CGRectMake(x, W - pad - 110, W - x - pad, 50) withAttributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:40 weight:UIFontWeightBold], NSForegroundColorAttributeName: UIColor.whiteColor }];
        [artist drawInRect:CGRectMake(x, W - pad - 55, W - x - pad, 44) withAttributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:32 weight:UIFontWeightMedium], NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.7] }];
    }];
}
