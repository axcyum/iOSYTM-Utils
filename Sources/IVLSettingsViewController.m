#import "IVLSettingsViewController.h"
#import "IVLSettings.h"
#import "IVLLocalization.h"
#import "IVLLyricsService.h"
#import "IVLTranslator.h"

#ifndef IVL_VERSION
#define IVL_VERSION "1.0.0"
#endif

typedef NS_ENUM(NSInteger, IVLRowType) { IVLRowSwitch, IVLRowSegment, IVLRowStepper, IVLRowLink, IVLRowAction, IVLRowInfo };

@interface IVLRow : NSObject
@property (nonatomic) IVLRowType type;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSArray *options;           // segment titles
@property (nonatomic, copy) NSArray<NSNumber *> *values; // segment values (default 0..n-1)
@property (nonatomic) double min, max, step;
@property (nonatomic, copy) NSString *(^format)(double v);
@property (nonatomic, copy) void (^action)(UIViewController *vc);
@property (nonatomic, copy) NSString *(^detail)(void);
@end
@implementation IVLRow
+ (instancetype)type:(IVLRowType)t key:(NSString *)k title:(NSString *)title {
    IVLRow *r = [self new]; r.type = t; r.key = k; r.title = title; return r;
}
@end

@interface IVLSection : NSObject
@property (nonatomic, copy) NSString *title, *footer;
@property (nonatomic, copy) NSArray<IVLRow *> *rows;
@end
@implementation IVLSection
+ (instancetype)title:(NSString *)t footer:(NSString *)f rows:(NSArray *)rows {
    IVLSection *s = [self new]; s.title = t; s.footer = f; s.rows = rows; return s;
}
@end

@implementation IVLSettingsViewController {
    NSArray<IVLSection *> *_sections;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"ivLyrics";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    [self buildSections];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)buildSections {
    IVLRow *(^sw)(NSString *, NSString *) = ^(NSString *k, NSString *t) { return [IVLRow type:IVLRowSwitch key:k title:t]; };
    IVLRow *(^seg)(NSString *, NSString *, NSArray *) = ^(NSString *k, NSString *t, NSArray *o) {
        IVLRow *r = [IVLRow type:IVLRowSegment key:k title:t]; r.options = o; return r;
    };

    IVLRow *size = [IVLRow type:IVLRowStepper key:IVLKeyFontSize title:IVLLoc(@"text_size")];
    size.min = 16; size.max = 52; size.step = 2;
    size.format = ^NSString *(double v) { return [NSString stringWithFormat:@"%.0f pt", v]; };

    IVLRow *lang = [IVLRow type:IVLRowLink key:IVLKeyTranslationLang title:IVLLoc(@"translation_lang")];
    lang.detail = ^NSString *{ return [IVLLanguagePickerViewController nameForCode:[IVLSettings objectForKey:IVLKeyTranslationLang]]; };
    lang.action = ^(UIViewController *vc) { [vc.navigationController pushViewController:[IVLLanguagePickerViewController new] animated:YES]; };

    IVLRow *sources = [IVLRow type:IVLRowLink key:IVLKeyProviderOrder title:IVLLoc(@"sources_order")];
    sources.detail = ^NSString *{
        NSMutableArray *names = [NSMutableArray array];
        for (NSString *pid in [IVLSettings enabledProviderIDs]) [names addObject:[IVLSettings nameForProvider:pid]];
        return names.count ? [names componentsJoinedByString:@" › "] : IVLLoc(@"off");
    };
    sources.action = ^(UIViewController *vc) { [vc.navigationController pushViewController:[IVLProvidersViewController new] animated:YES]; };

    IVLRow *offset = [IVLRow type:IVLRowStepper key:IVLKeyGlobalOffset title:IVLLoc(@"global_offset")];
    offset.min = -3000; offset.max = 3000; offset.step = 50;
    offset.format = ^NSString *(double v) { return [NSString stringWithFormat:@"%+.2fs", v / 1000.0]; };

    IVLRow *resume = seg(IVLKeyAutoResume, IVLLoc(@"auto_resume"), @[IVLLoc(@"off"), @"3s", @"5s", @"10s"]);
    resume.values = @[@0, @3, @5, @10];

    IVLRow *clear = [IVLRow type:IVLRowAction key:@"" title:IVLLoc(@"clear_cache")];
    clear.detail = ^NSString *{
        return [NSByteCountFormatter stringFromByteCount:(long long)[[IVLLyricsService shared] cacheSize] countStyle:NSByteCountFormatterCountStyleFile];
    };
    clear.action = ^(UIViewController *vc) {
        [[IVLLyricsService shared] clearCache];
        [[IVLTranslator shared] clearCache];
        [((UITableViewController *)vc).tableView reloadData];
    };

    IVLRow *version = [IVLRow type:IVLRowInfo key:@"" title:IVLLoc(@"version")];
    version.detail = ^NSString *{ return @IVL_VERSION; };

    _sections = @[
        [IVLSection title:IVLLoc(@"sec_general") footer:IVLLoc(@"footer_general") rows:@[
            sw(IVLKeyEnabled, IVLLoc(@"enabled")),
            sw(IVLKeyShowButton, IVLLoc(@"show_button")),
            sw(IVLKeyMiniLyric, IVLLoc(@"mini_lyric")),
            sw(IVLKeyKeepAwake, IVLLoc(@"keep_awake")),
        ]],
        [IVLSection title:IVLLoc(@"sec_display") footer:IVLLoc(@"footer_display") rows:@[
            size,
            seg(IVLKeyAlignment, IVLLoc(@"alignment"), @[IVLLoc(@"align_left"), IVLLoc(@"align_center")]),
            sw(IVLKeyKaraoke, IVLLoc(@"karaoke")),
            sw(IVLKeyShowBreaks, IVLLoc(@"show_breaks")),
            seg(IVLKeyBackground, IVLLoc(@"background"), @[IVLLoc(@"bg_artwork"), IVLLoc(@"bg_solid")]),
        ]],
        [IVLSection title:IVLLoc(@"sec_translation") footer:IVLLoc(@"footer_translation") rows:@[
            sw(IVLKeyTranslation, IVLLoc(@"translation")),
            lang,
            seg(IVLKeyPronunciation, IVLLoc(@"pronunciation"), @[IVLLoc(@"off"), IVLLoc(@"romaji"), IVLLoc(@"kana")]),
        ]],
        [IVLSection title:IVLLoc(@"sec_sources") footer:IVLLoc(@"footer_sources") rows:@[sources]],
        [IVLSection title:IVLLoc(@"sec_sync") footer:IVLLoc(@"footer_sync") rows:@[offset, resume]],
        [IVLSection title:IVLLoc(@"sec_data") footer:nil rows:@[clear]],
        [IVLSection title:IVLLoc(@"sec_about") footer:IVLLoc(@"footer_about") rows:@[version]],
    ];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return _sections.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _sections[section].rows.count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return _sections[section].title; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { return _sections[section].footer; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    IVLRow *row = _sections[indexPath.section].rows[indexPath.row];
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    c.textLabel.text = row.title;
    c.textLabel.numberOfLines = 0;
    c.selectionStyle = UITableViewCellSelectionStyleNone;

    switch (row.type) {
        case IVLRowSwitch: {
            UISwitch *s = [UISwitch new];
            s.on = [IVLSettings boolForKey:row.key];
            NSString *key = row.key;
            [s addAction:[UIAction actionWithHandler:^(UIAction *a) { [IVLSettings setBool:((UISwitch *)a.sender).on forKey:key]; }] forControlEvents:UIControlEventValueChanged];
            c.accessoryView = s;
            break;
        }
        case IVLRowSegment: {
            UISegmentedControl *sc = [[UISegmentedControl alloc] initWithItems:row.options];
            NSArray<NSNumber *> *values = row.values;
            NSInteger cur = [IVLSettings integerForKey:row.key];
            NSInteger idx = values ? (NSInteger)[values indexOfObject:@(cur)] : cur;
            sc.selectedSegmentIndex = (idx == NSNotFound || idx >= (NSInteger)row.options.count) ? 0 : idx;
            NSString *key = row.key;
            [sc addAction:[UIAction actionWithHandler:^(UIAction *a) {
                NSInteger i = ((UISegmentedControl *)a.sender).selectedSegmentIndex;
                [IVLSettings setObject:(values ? values[i] : @(i)) forKey:key];
            }] forControlEvents:UIControlEventValueChanged];
            [sc sizeToFit];
            c.accessoryView = sc;
            break;
        }
        case IVLRowStepper: {
            UIStepper *st = [UIStepper new];
            st.minimumValue = row.min; st.maximumValue = row.max; st.stepValue = row.step;
            st.value = [IVLSettings doubleForKey:row.key];
            NSString *key = row.key;
            NSString *(^fmt)(double) = row.format;
            [st addAction:[UIAction actionWithHandler:^(UIAction *a) {
                [IVLSettings setObject:@(((UIStepper *)a.sender).value) forKey:key];
            }] forControlEvents:UIControlEventValueChanged];
            UIView *wrap = [[UIView alloc] initWithFrame:CGRectMake(0, 0, st.intrinsicContentSize.width + 76, 32)];
            UILabel *val = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 68, 32)];
            val.textAlignment = NSTextAlignmentRight;
            val.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular];
            val.textColor = UIColor.secondaryLabelColor;
            val.text = row.format(st.value);
            st.frame = CGRectMake(76, 0, st.intrinsicContentSize.width, 32);
            [st addAction:[UIAction actionWithHandler:^(UIAction *a) { val.text = fmt(((UIStepper *)a.sender).value); }] forControlEvents:UIControlEventValueChanged];
            [wrap addSubview:val];
            [wrap addSubview:st];
            c.detailTextLabel.text = nil;
            c.accessoryView = wrap;
            break;
        }
        case IVLRowLink:
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            c.detailTextLabel.text = row.detail ? row.detail() : nil;
            c.selectionStyle = UITableViewCellSelectionStyleDefault;
            break;
        case IVLRowAction:
            c.textLabel.textColor = UIColor.systemRedColor;
            c.detailTextLabel.text = row.detail ? row.detail() : nil;
            c.selectionStyle = UITableViewCellSelectionStyleDefault;
            break;
        case IVLRowInfo:
            c.detailTextLabel.text = row.detail ? row.detail() : nil;
            break;
    }
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    IVLRow *row = _sections[indexPath.section].rows[indexPath.row];
    if (row.action) row.action(self);
}

@end

#pragma mark - Providers

@implementation IVLProvidersViewController {
    NSMutableArray<NSString *> *_ids;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = IVLLoc(@"sec_sources");
    _ids = [[IVLSettings providerIDs] mutableCopy];
    self.tableView.editing = YES;
    self.tableView.allowsSelectionDuringEditing = NO;
}

+ (NSString *)detailFor:(NSString *)pid {
    if ([pid isEqualToString:@"youtube"]) return IVLLoc(@"src_youtube");
    if ([pid isEqualToString:@"lyricsplus"]) return IVLLoc(@"src_lyricsplus");
    if ([pid isEqualToString:@"unison"]) return IVLLoc(@"src_unison");
    if ([pid isEqualToString:@"lyrically"]) return IVLLoc(@"src_lyrically");
    return IVLLoc(@"src_lrclib");
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _ids.count; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { return IVLLoc(@"footer_sources_order"); }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSString *pid = _ids[indexPath.row];
    c.textLabel.text = [NSString stringWithFormat:@"%ld. %@", (long)indexPath.row + 1, [IVLSettings nameForProvider:pid]];
    c.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    c.detailTextLabel.text = [IVLProvidersViewController detailFor:pid];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.detailTextLabel.numberOfLines = 0;
    c.showsReorderControl = YES;
    UISwitch *sw = [UISwitch new];
    NSString *key = [IVLSettings enableKeyForProvider:pid];
    sw.on = [IVLSettings boolForKey:key];
    [sw addAction:[UIAction actionWithHandler:^(UIAction *a) { [IVLSettings setBool:((UISwitch *)a.sender).on forKey:key]; }] forControlEvents:UIControlEventValueChanged];
    c.editingAccessoryView = sw;
    return c;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath { return UITableViewCellEditingStyleNone; }
- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath { return NO; }
- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath { return YES; }

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    NSString *pid = _ids[from.row];
    [_ids removeObjectAtIndex:from.row];
    [_ids insertObject:pid atIndex:to.row];
    [IVLSettings setProviderIDs:_ids];
    dispatch_async(dispatch_get_main_queue(), ^{ [tableView reloadData]; });   // renumber
}

@end

#pragma mark - Language picker

@implementation IVLLanguagePickerViewController

+ (NSArray<NSArray<NSString *> *> *)languages {
    return @[
        @[@"ja", @"日本語"], @[@"en", @"English"], @[@"ko", @"한국어"], @[@"zh-CN", @"简体中文"], @[@"zh-TW", @"繁體中文"],
        @[@"es", @"Español"], @[@"fr", @"Français"], @[@"de", @"Deutsch"], @[@"it", @"Italiano"], @[@"pt", @"Português"],
        @[@"ru", @"Русский"], @[@"sv", @"Svenska"], @[@"cs", @"Čeština"], @[@"tr", @"Türkçe"], @[@"ar", @"العربية"],
        @[@"fa", @"فارسی"], @[@"hi", @"हिन्दी"], @[@"bn", @"বাংলা"], @[@"th", @"ไทย"], @[@"vi", @"Tiếng Việt"],
        @[@"id", @"Bahasa Indonesia"], @[@"ms", @"Bahasa Melayu"],
    ];
}

+ (NSString *)nameForCode:(NSString *)code {
    for (NSArray *l in [self languages]) if ([l[0] isEqualToString:code]) return l[1];
    return code ?: @"";
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = IVLLoc(@"translation_lang");
    if (self.navigationController.viewControllers.firstObject == self) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    }
}

- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return [IVLLanguagePickerViewController languages].count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"l"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"l"];
    NSArray *l = [IVLLanguagePickerViewController languages][indexPath.row];
    c.textLabel.text = l[1];
    c.detailTextLabel.text = l[0];
    c.accessoryType = [l[0] isEqualToString:[IVLSettings objectForKey:IVLKeyTranslationLang]] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray *l = [IVLLanguagePickerViewController languages][indexPath.row];
    [IVLSettings setObject:l[0] forKey:IVLKeyTranslationLang];
    [tableView reloadData];
    if (self.navigationController.viewControllers.firstObject == self) [self done];
    else [self.navigationController popViewControllerAnimated:YES];
}

@end
