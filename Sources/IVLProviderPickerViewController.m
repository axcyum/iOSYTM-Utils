#import "IVLProviderPickerViewController.h"
#import "IVLSearchViewController.h"
#import "IVLLyricsService.h"
#import "IVLPlaybackManager.h"
#import "IVLSettings.h"
#import "IVLLocalization.h"

typedef NS_ENUM(NSInteger, IVLProbeState) { IVLProbeLoading, IVLProbeFound, IVLProbeEmpty, IVLProbeFailed };

@implementation IVLProviderPickerViewController {
    NSArray<NSString *> *_ids;
    NSMutableDictionary<NSString *, IVLLyrics *> *_results;
    NSMutableDictionary<NSString *, NSNumber *> *_states;
    IVLTrack *_track;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = IVLLoc(@"choose_provider");
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.clockwise"] style:UIBarButtonItemStylePlain target:self action:@selector(probe)];
    _ids = [IVLSettings providerIDs];   // every provider, also disabled ones
    _track = [IVLPlaybackManager shared].track;
    [self probe];
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)probe {
    _results = [NSMutableDictionary dictionary];
    _states = [NSMutableDictionary dictionary];
    for (NSString *pid in _ids) _states[pid] = @(IVLProbeLoading);
    [self.tableView reloadData];
    IVLTrack *track = _track;
    if (!track) return;
    for (NSString *pid in _ids) {
        [[IVLLyricsService shared] fetchProvider:pid track:track completion:^(IVLLyrics *ly, NSError *err) {
            if (track != self->_track) return;
            if (ly) self->_results[pid] = ly;
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
    return section == 1 ? _ids.count : 1;
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

    if (indexPath.section == 0) {
        c.textLabel.text = IVLLoc(@"auto_provider");
        c.imageView.image = [UIImage systemImageNamed:@"wand.and.stars"];
        c.accessoryType = (cur && !cur.manual) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        return c;
    }
    if (indexPath.section == 2) {
        c.textLabel.text = IVLLoc(@"search_lyrics");
        c.detailTextLabel.text = IVLLoc(@"search_lrclib_hint");
        c.imageView.image = [UIImage systemImageNamed:@"magnifyingglass"];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }

    NSString *pid = _ids[indexPath.row];
    NSString *name = [IVLSettings nameForProvider:pid];
    c.textLabel.text = name;
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
            c.accessoryType = (cur.manual && [cur.source isEqualToString:ly.source]) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
            break;
        case IVLProbeEmpty:
            c.detailTextLabel.text = IVLLoc(@"not_found");
            c.textLabel.alpha = 0.5;
            break;
        case IVLProbeFailed:
            c.detailTextLabel.text = IVLLoc(@"provider_error");
            c.textLabel.alpha = 0.5;
            break;
    }
    if (![IVLSettings boolForKey:[IVLSettings enableKeyForProvider:pid]]) {
        c.detailTextLabel.text = [NSString stringWithFormat:@"%@ (%@)", c.detailTextLabel.text ?: @"", IVLLoc(@"disabled_in_settings")];
    }
    c.selectionStyle = st == IVLProbeFound ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        [[IVLPlaybackManager shared] reloadLyrics];   // drops the pinned choice and re-runs automatic selection
        [self close];
        return;
    }
    if (indexPath.section == 2) {
        [self.navigationController pushViewController:[IVLSearchViewController new] animated:YES];
        return;
    }
    IVLLyrics *ly = _results[_ids[indexPath.row]];
    if (!ly) return;
    [[IVLPlaybackManager shared] useManualLyrics:ly];
    [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
    [self close];
}

@end
