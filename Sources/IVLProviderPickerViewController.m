#import "IVLProviderPickerViewController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "IVLSearchViewController.h"
#import "IVLLyricsService.h"
#import "IVLPlaybackManager.h"
#import "IVLSettings.h"
#import "IVLLocalization.h"
#import "IVLLyricsService+Private.h"
#import "IVLSettingsViewController.h"

/// All subtitle tracks of the video; picking one pins it to this song.
@interface IVLCaptionTrackListViewController : UITableViewController
@property (nonatomic, strong) IVLTrack *track;
@end

/// Repository picker when multiple GitHub LRC repositories are configured.
@interface IVLGitHubLRCRepoPickerViewController : UITableViewController
@property (nonatomic, strong) IVLTrack *track;
@end

/// Searchable list of root-level LRC/TTML files in a chosen GitHub repository.
@interface IVLGitHubLRCFilesViewController : UITableViewController <UISearchResultsUpdating>
@property (nonatomic, strong) IVLTrack *track;
@property (nonatomic, copy) NSString *repo;
@property (nonatomic, copy) NSString *branch;
@end

typedef NS_ENUM(NSInteger, IVLProbeState) { IVLProbeLoading, IVLProbeFound, IVLProbeEmpty, IVLProbeFailed };

@interface IVLProviderPickerViewController () <UIDocumentPickerDelegate>
@end

@implementation IVLProviderPickerViewController {
    NSArray<NSString *> *_ids;
    NSMutableDictionary<NSString *, IVLLyrics *> *_results;
    NSMutableDictionary<NSString *, NSNumber *> *_states;
    NSMutableDictionary<NSString *, NSString *> *_reasons;
    IVLTrack *_track;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = IVLLoc(@"choose_provider");
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.clockwise"] style:UIBarButtonItemStylePlain target:self action:@selector(probe)];
    BOOL ghOn = [IVLSettings boolForKey:IVLKeyProviderGitHub];
    NSMutableArray<NSString *> *list = [[IVLSettings providerIDs] mutableCopy];
    if (!ghOn) [list removeObject:@"github"];   // hide GitHub LRC completely when OFF in settings
    _ids = list;
    _track = [IVLPlaybackManager shared].track;
    [self probe];
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)probe {
    _results = [NSMutableDictionary dictionary];
    _states = [NSMutableDictionary dictionary];
    _reasons = [NSMutableDictionary dictionary];
    for (NSString *pid in _ids) _states[pid] = @(IVLProbeLoading);
    [self.tableView reloadData];
    IVLTrack *track = _track;
    if (!track) return;
    for (NSString *pid in _ids) {
        [[IVLLyricsService shared] fetchProvider:pid track:track completion:^(IVLLyrics *ly, NSError *err) {
            if (track != self->_track) return;
            if (ly) self->_results[pid] = ly;
            if (!ly && err.localizedDescription.length) self->_reasons[pid] = err.localizedDescription;
            BOOL notFound = err.code == 404;
            if (notFound) err = nil;
            self->_states[pid] = @(ly ? IVLProbeFound : (err ? IVLProbeFailed : IVLProbeEmpty));
            NSUInteger row = [self->_ids indexOfObject:pid];
            if (row != NSNotFound) {
                [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:row inSection:1]] withRowAnimation:UITableViewRowAnimationNone];
            }
        }];
    }
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 1) return _ids.count;
    if (section == 2) return [IVLSettings boolForKey:IVLKeyProviderGitHub] ? 3 : 2;
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) {
        IVLLyrics *cur = [IVLPlaybackManager shared].lyrics;
        return cur.source.length ? [NSString stringWithFormat:IVLLoc(@"current_provider_fmt"), cur.source] : nil;
    }
    return section == 1 ? IVLLoc(@"sec_sources") : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return IVLLoc(@"footer_auto");
    if (section == 1) return IVLLoc(@"footer_pick_provider");
    return nil;
}

- (NSString *)syncLabel:(IVLLyrics *)ly {
    NSUInteger n = 0;
    for (IVLLyricLine *l in ly.lines) if (!l.instrumental) n++;
    NSString *kind = ly.karaoke ? IVLLoc(@"sync_word") : (ly.synced ? IVLLoc(@"sync_line") : IVLLoc(@"sync_none"));
    NSString *firstLine = @"";
    for (IVLLyricLine *l in ly.lines) if (!l.instrumental && l.text.length) { firstLine = l.text; break; }
    return [NSString stringWithFormat:@"%@ · %lu %@\n%@", kind, (unsigned long)n, IVLLoc(@"lines_unit"), firstLine];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.detailTextLabel.numberOfLines = 2;
    IVLLyrics *cur = [IVLPlaybackManager shared].lyrics;
    NSArray<NSString *> *keys = [IVLLyricsService storageKeysForTrack:_track];
    NSString *pinned = [IVLSettings pinnedProviderForKeys:keys];

    if (indexPath.section == 0) {
        c.textLabel.text = IVLLoc(@"auto_provider");
        c.imageView.image = [UIImage systemImageNamed:@"wand.and.stars"];
        BOOL isAuto = !pinned.length && (!cur || !cur.manual);
        c.accessoryType = isAuto ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        return c;
    }
    if (indexPath.section == 2) {
        BOOL ghOn = [IVLSettings boolForKey:IVLKeyProviderGitHub];
        if (indexPath.row == 0) {
            c.textLabel.text = IVLLoc(@"search_lyrics");
            if ([pinned isEqualToString:@"lrclib_manual"]) {
                NSString *savedSrc = cur.source.length ? cur.source : @"LRCLIB";
                c.detailTextLabel.text = [NSString stringWithFormat:@"✓ %@", savedSrc];
                c.detailTextLabel.textColor = UIColor.systemGreenColor;
            } else {
                c.detailTextLabel.text = IVLLoc(@"search_lrclib_hint");
            }
            c.imageView.image = [UIImage systemImageNamed:@"magnifyingglass"];
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (ghOn && indexPath.row == 1) {
            c.textLabel.text = IVLLoc(@"browse_github_lrc");
            if ([pinned isEqualToString:@"github_manual"]) {
                NSString *savedSrc = cur.source.length ? cur.source : @"GitHub LRC";
                c.detailTextLabel.text = [NSString stringWithFormat:@"✓ %@", savedSrc];
                c.detailTextLabel.textColor = UIColor.systemGreenColor;
            } else {
                c.detailTextLabel.text = IVLLoc(@"browse_github_lrc_hint");
            }
            c.imageView.image = [UIImage systemImageNamed:@"folder.badge.magnifyingglass"] ?: [UIImage systemImageNamed:@"folder"];
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            c.textLabel.text = IVLLoc(@"import_lrc_file");
            if ([pinned isEqualToString:@"lrc_file"]) {
                NSString *savedSrc = cur.source.length ? cur.source : @"LRC";
                c.detailTextLabel.text = [NSString stringWithFormat:@"✓ %@", savedSrc];
                c.detailTextLabel.textColor = UIColor.systemGreenColor;
            } else {
                c.detailTextLabel.text = IVLLoc(@"import_lrc_hint");
            }
            c.imageView.image = [UIImage systemImageNamed:@"doc.text"];
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        return c;
    }

    NSString *pid = _ids[indexPath.row];
    NSString *name = [IVLSettings nameForProvider:pid];
    BOOL isPinnedThis = [pinned isEqualToString:pid]
        || ([pid isEqualToString:@"captions"] && [pinned isEqualToString:@"captions_manual"])
        || (!pinned.length && cur.manual && [cur.source isEqualToString:_results[pid].source]);
    c.textLabel.text = ([pid isEqualToString:@"captions"] && isPinnedThis) ? [@"✓ " stringByAppendingString:name] : name;
    c.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    IVLProbeState st = (IVLProbeState)[_states[pid] integerValue];
    IVLLyrics *ly = _results[pid];
    switch (st) {
        case IVLProbeLoading: {
            UIActivityIndicatorView *sp = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
            [sp startAnimating];
            c.accessoryView = sp;
            c.detailTextLabel.text = IVLLoc(@"loading");
            break;
        }
        case IVLProbeFound:
            c.detailTextLabel.text = [self syncLabel:ly];
            c.accessoryType = isPinnedThis ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
            break;
        case IVLProbeEmpty:
            c.detailTextLabel.text = self->_reasons[pid] ?: IVLLoc(@"not_found");
            c.textLabel.alpha = isPinnedThis ? 1.0 : 0.5;
            if (isPinnedThis) c.accessoryType = UITableViewCellAccessoryCheckmark;
            break;
        case IVLProbeFailed:
            c.detailTextLabel.text = self->_reasons[pid] ?: IVLLoc(@"provider_error");
            c.textLabel.alpha = isPinnedThis ? 1.0 : 0.5;
            if (isPinnedThis) c.accessoryType = UITableViewCellAccessoryCheckmark;
            break;
    }
    if (![IVLSettings boolForKey:[IVLSettings enableKeyForProvider:pid]]) {
        c.detailTextLabel.text = [NSString stringWithFormat:@"%@ (%@)", c.detailTextLabel.text ?: @"", IVLLoc(@"disabled_in_settings")];
    }
    c.selectionStyle = st == IVLProbeFound ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    if ([pid isEqualToString:@"captions"] && st != IVLProbeLoading) {
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;   // choose the subtitle language for this song
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    if ([pid isEqualToString:@"github"] && st != IVLProbeLoading && ![IVLSettings githubLRCRepos].count) {
        c.detailTextLabel.text = IVLLoc(@"github_lrc_tap_to_setup");
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return c;
}

- (void)openGitHubLRCBrowser {
    NSArray<NSDictionary<NSString *, NSString *> *> *repos = [IVLSettings githubLRCRepos];
    if (!repos.count) {
        [self.navigationController pushViewController:[IVLGitHubLRCReposViewController new] animated:YES];
        return;
    }
    if (repos.count == 1) {
        IVLGitHubLRCFilesViewController *vc = [IVLGitHubLRCFilesViewController new];
        vc.track = _track;
        vc.repo = repos[0][@"repo"];
        vc.branch = repos[0][@"branch"];
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }
    IVLGitHubLRCRepoPickerViewController *vc = [IVLGitHubLRCRepoPickerViewController new];
    vc.track = _track;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        [[IVLPlaybackManager shared] resetManualChoiceAndReload];   // drops the pinned choice and re-runs automatic selection
        [self close];
        return;
    }
    if (indexPath.section == 2) {
        BOOL ghOn = [IVLSettings boolForKey:IVLKeyProviderGitHub];
        if (indexPath.row == 0) {
            [self.navigationController pushViewController:[IVLSearchViewController new] animated:YES];
        } else if (ghOn && indexPath.row == 1) {
            [self openGitHubLRCBrowser];
        } else {
            UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
            picker.delegate = self;
            picker.allowsMultipleSelection = NO;
            [self presentViewController:picker animated:YES completion:nil];
        }
        return;
    }
    NSString *pid = _ids[indexPath.row];
    if ([pid isEqualToString:@"captions"]) {
        IVLCaptionTrackListViewController *list = [IVLCaptionTrackListViewController new];
        list.track = _track;
        [self.navigationController pushViewController:list animated:YES];
        return;
    }
    if ([pid isEqualToString:@"github"] && ![IVLSettings githubLRCRepos].count) {
        [self.navigationController pushViewController:[IVLGitHubLRCReposViewController new] animated:YES];
        return;
    }
    IVLLyrics *ly = _results[pid];
    if (!ly) return;
    [[IVLPlaybackManager shared] useManualLyrics:ly providerID:pid];
    [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
    [self close];
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (scoped) [url stopAccessingSecurityScopedResource];

    NSString *fileName = url.lastPathComponent ?: @"lyrics.lrc";
    IVLLyrics *ly = [IVLLyricsService parseLyricsData:data fileName:fileName durationMs:(NSInteger)(_track.duration * 1000)];
    if (!ly.lines.count) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:IVLLoc(@"import_lrc_failed")
                                                                   message:fileName
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    ly.source = [NSString stringWithFormat:@"LRC (%@)", fileName];
    [[IVLPlaybackManager shared] useManualLyrics:ly providerID:@"lrc_file"];
    [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
    [self close];
}

@end

@implementation IVLCaptionTrackListViewController {
    NSArray<NSDictionary *> *_tracks;
    NSString *_label, *_failure;
    BOOL _loading;
    NSInteger _busyRow;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = IVLLoc(@"caption_tracks");
    _loading = YES;
    _busyRow = -1;
    UIBarButtonItem *lang = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"globe"] style:UIBarButtonItemStylePlain target:self action:@selector(openDefault)];
    self.navigationItem.rightBarButtonItem = lang;
    [[IVLLyricsService shared] captionTrackListForTrack:self.track completion:^(NSArray *tracks, NSString *label, NSString *failure) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableArray *manual = [NSMutableArray array];
            for (NSDictionary *t in tracks) if (![t[@"asr"] boolValue]) [manual addObject:t];
            self->_tracks = manual;
            self->_label = label ?: @"字幕";
            self->_failure = failure;
            self->_loading = NO;
            [self.tableView reloadData];
        });
    }];
}

- (void)openDefault {
    IVLLanguagePickerViewController *p = [IVLLanguagePickerViewController new];
    p.settingsKey = IVLKeyCaptionLang;
    [self.navigationController pushViewController:p animated:YES];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _loading ? 1 : MAX(1, (NSInteger)_tracks.count); }

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { return IVLLoc(@"footer_caption_tracks"); }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    if (_loading || !_tracks.count) {
        c.textLabel.text = _loading ? IVLLoc(@"loading") : (_failure ?: IVLLoc(@"not_found"));
        c.textLabel.numberOfLines = 0;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }
    NSDictionary *t = _tracks[indexPath.row];
    c.textLabel.text = [t[@"name"] length] ? t[@"name"] : t[@"lang"];
    c.detailTextLabel.text = t[@"lang"];
    NSDictionary *autoPick = IVLPickCaptionTrack(_tracks, self.track);
    if ([autoPick[@"url"] isEqual:t[@"url"]]) c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", t[@"lang"], IVLLoc(@"caption_auto_pick")];
    if (indexPath.row == _busyRow) {
        UIActivityIndicatorView *sp = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [sp startAnimating];
        c.accessoryView = sp;
    }
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_loading || indexPath.row >= (NSInteger)_tracks.count || _busyRow >= 0) return;
    _busyRow = indexPath.row;
    [tableView reloadData];
    NSDictionary *t = _tracks[indexPath.row];
    [[IVLLyricsService shared] fetchCaptionTrack:t durationMs:(NSInteger)(self.track.duration * 1000) label:_label completion:^(IVLLyrics *ly, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_busyRow = -1;
            [self.tableView reloadData];
            if (!ly) {
                UIAlertController *a = [UIAlertController alertControllerWithTitle:IVLLoc(@"not_found") message:err.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
                [self presentViewController:a animated:YES completion:nil];
                return;
            }
            [[IVLPlaybackManager shared] useManualLyrics:ly providerID:@"captions_manual"];
            [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
            [self dismissViewControllerAnimated:YES completion:nil];
        });
    }];
}

@end

#pragma mark - GitHub LRC Repository Picker & File Browser

@implementation IVLGitHubLRCRepoPickerViewController {
    NSArray<NSDictionary<NSString *, NSString *> *> *_repos;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = IVLLoc(@"github_lrc_pick_repo");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"gearshape"] style:UIBarButtonItemStylePlain target:self action:@selector(openManage)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _repos = [IVLSettings githubLRCRepos];
    [self.tableView reloadData];
}

- (void)openManage {
    [self.navigationController pushViewController:[IVLGitHubLRCReposViewController new] animated:YES];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _repos.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSDictionary *d = _repos[indexPath.row];
    c.textLabel.text = d[@"repo"];
    c.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    NSString *br = d[@"branch"];
    c.detailTextLabel.text = br.length ? [NSString stringWithFormat:@"branch: %@", br] : IVLLoc(@"github_lrc_branch_placeholder");
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.imageView.image = [UIImage systemImageNamed:@"folder.fill"];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *d = _repos[indexPath.row];
    IVLGitHubLRCFilesViewController *vc = [IVLGitHubLRCFilesViewController new];
    vc.track = self.track;
    vc.repo = d[@"repo"];
    vc.branch = d[@"branch"];
    [self.navigationController pushViewController:vc animated:YES];
}

@end

@implementation IVLGitHubLRCFilesViewController {
    UISearchController *_search;
    NSArray<NSDictionary *> *_allFiles;
    NSArray<NSDictionary *> *_filtered;
    BOOL _loading;
    NSString *_errorMsg;
    NSInteger _busyRow;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [self.repo componentsSeparatedByString:@"/"].lastObject ?: self.repo;
    _busyRow = -1;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.clockwise"] style:UIBarButtonItemStylePlain target:self action:@selector(reloadFromGitHub)];

    _search = [[UISearchController alloc] initWithSearchResultsController:nil];
    _search.obscuresBackgroundDuringPresentation = NO;
    _search.searchResultsUpdater = self;
    _search.searchBar.placeholder = IVLLoc(@"github_lrc_search_placeholder");
    self.navigationItem.searchController = _search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    [self loadBypassCache:NO];
}

- (void)reloadFromGitHub { [self loadBypassCache:YES]; }

- (void)loadBypassCache:(BOOL)bypass {
    _loading = YES;
    _errorMsg = nil;
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    [[IVLLyricsService shared] listGitHubLRCFilesForRepo:self.repo branch:self.branch bypassCache:bypass completion:^(NSArray<NSDictionary *> *files, NSError *err) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_loading = NO;
        strongSelf->_allFiles = files ?: @[];
        strongSelf->_errorMsg = err.localizedDescription;
        [strongSelf applyFilter];
    }];
}

- (void)applyFilter {
    NSString *q = [_search.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!q.length) {
        _filtered = _allFiles ?: @[];
    } else {
        NSString *lq = q.lowercaseString;
        NSMutableArray *m = [NSMutableArray array];
        for (NSDictionary *f in _allFiles) {
            NSString *name = f[@"name"] ?: @"";
            if ([name.lowercaseString containsString:lq]) [m addObject:f];
        }
        _filtered = m;
    }
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self applyFilter];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (_loading) return 1;
    return MAX(1, (NSInteger)_filtered.count);
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return IVLLoc(@"search_footer");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    if (_loading || !_filtered.count) {
        c.textLabel.text = _loading ? IVLLoc(@"loading") : (_errorMsg ?: IVLLoc(@"github_lrc_empty"));
        c.textLabel.numberOfLines = 0;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        if (_loading) {
            UIActivityIndicatorView *sp = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
            [sp startAnimating];
            c.accessoryView = sp;
        }
        return c;
    }
    NSDictionary *f = _filtered[indexPath.row];
    NSString *name = f[@"name"] ?: @"";
    c.textLabel.text = [name stringByDeletingPathExtension];
    c.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    c.detailTextLabel.text = name;
    c.imageView.image = [UIImage systemImageNamed:@"doc.text"];
    if (indexPath.row == _busyRow) {
        UIActivityIndicatorView *sp = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [sp startAnimating];
        c.accessoryView = sp;
    }
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_loading || indexPath.row >= (NSInteger)_filtered.count || _busyRow >= 0) return;
    _busyRow = indexPath.row;
    [tableView reloadData];
    NSDictionary *f = _filtered[indexPath.row];
    __weak typeof(self) weakSelf = self;
    [[IVLLyricsService shared] downloadGitHubLRCFile:f repo:self.repo durationMs:(NSInteger)(self.track.duration * 1000) completion:^(IVLLyrics *ly, NSError *err) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_busyRow = -1;
        [strongSelf.tableView reloadData];
        if (!ly.lines.count) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:IVLLoc(@"import_lrc_failed")
                                                                       message:(err.localizedDescription ?: f[@"name"])
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [strongSelf presentViewController:a animated:YES completion:nil];
            return;
        }
        [[IVLPlaybackManager shared] useManualLyrics:ly providerID:@"github_manual"];
        [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
        [strongSelf dismissViewControllerAnimated:YES completion:nil];
    }];
}

@end
