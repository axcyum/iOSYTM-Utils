#import "IVLSearchViewController.h"
#import "IVLLyricsService.h"
#import "IVLPlaybackManager.h"
#import "IVLLocalization.h"

@interface IVLSearchViewController () <UISearchBarDelegate>
@end

@implementation IVLSearchViewController {
    UISearchController *_search;
    NSArray<IVLSearchResult *> *_results;
    UIActivityIndicatorView *_spinner;
    NSUInteger _token;
    BOOL _searched;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = IVLLoc(@"search_lyrics");
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];

    _search = [[UISearchController alloc] initWithSearchResultsController:nil];
    _search.obscuresBackgroundDuringPresentation = NO;
    _search.searchBar.delegate = self;
    _search.searchBar.placeholder = IVLLoc(@"search_placeholder");
    self.navigationItem.searchController = _search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:_spinner];

    IVLTrack *t = [IVLPlaybackManager shared].track;
    if (t) {
        NSString *q = [NSString stringWithFormat:@"%@ %@", [IVLLyricsService cleanTitle:t.title], [IVLLyricsService cleanArtist:t.artist]];
        _search.searchBar.text = q;
        [self runSearch:q];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!_search.searchBar.text.length) [_search.searchBar becomeFirstResponder];
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [self runSearch:searchBar.text];
    [searchBar resignFirstResponder];
}

- (void)runSearch:(NSString *)q {
    q = [q stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!q.length) return;
    NSUInteger token = ++_token;
    [_spinner startAnimating];
    [[IVLLyricsService shared] searchQuery:q completion:^(NSArray<IVLSearchResult *> *results, NSError *error) {
        if (token != self->_token) return;
        [self->_spinner stopAnimating];
        self->_results = results;
        self->_searched = YES;
        [self.tableView reloadData];
    }];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _results.count; }

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (_searched && !_results.count) return IVLLoc(@"no_results");
    return IVLLoc(@"search_footer");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"r"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"r"];
    IVLSearchResult *r = _results[indexPath.row];
    c.textLabel.text = r.title;
    c.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    NSMutableArray *sub = [NSMutableArray arrayWithObject:r.artist];
    if (r.album.length) [sub addObject:r.album];
    if (r.duration > 0) [sub addObject:[NSString stringWithFormat:@"%d:%02d", (int)r.duration / 60, (int)r.duration % 60]];
    c.detailTextLabel.text = [sub componentsJoinedByString:@" · "];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;

    UILabel *badge = [UILabel new];
    badge.text = [NSString stringWithFormat:@"  %@  ", r.lyrics.karaoke ? IVLLoc(@"sync_word") : (r.synced ? IVLLoc(@"sync_line") : IVLLoc(@"sync_none"))];
    badge.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    badge.textColor = r.synced ? UIColor.blackColor : UIColor.labelColor;
    badge.backgroundColor = r.synced ? UIColor.systemGreenColor : UIColor.tertiarySystemFillColor;
    badge.layer.cornerRadius = 8;
    badge.clipsToBounds = YES;
    [badge sizeToFit];
    CGRect f = badge.frame; f.size.height = 22; badge.frame = f;
    c.accessoryView = badge;

    // Preview of the first lines so the right version can be picked
    NSMutableArray *preview = [NSMutableArray array];
    for (IVLLyricLine *l in r.lyrics.lines) {
        if (!l.instrumental && l.text.length) [preview addObject:l.text];
        if (preview.count >= 2) break;
    }
    c.accessibilityHint = [preview componentsJoinedByString:@" / "];
    return c;
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    IVLSearchResult *r = _results[indexPath.row];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:^UIViewController *{
        UIViewController *vc = [UIViewController new];
        UITextView *tv = [UITextView new];
        tv.editable = NO;
        tv.font = [UIFont systemFontOfSize:15];
        tv.text = [r.lyrics plainText];
        tv.textContainerInset = UIEdgeInsetsMake(16, 12, 16, 12);
        vc.view = tv;
        vc.preferredContentSize = CGSizeMake(320, 420);
        return vc;
    } actionProvider:^UIMenu *(NSArray *s) {
        return [UIMenu menuWithTitle:@"" children:@[[UIAction actionWithTitle:IVLLoc(@"use_these") image:[UIImage systemImageNamed:@"checkmark"] identifier:nil handler:^(UIAction *a) {
            [self pick:r];
        }]]];
    }];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self pick:_results[indexPath.row]];
}

- (void)pick:(IVLSearchResult *)r {
    if (!r.lyrics) return;
    r.lyrics.source = r.title.length ? [NSString stringWithFormat:@"LRCLIB (%@)", r.title] : @"LRCLIB";
    [[IVLPlaybackManager shared] useManualLyrics:r.lyrics providerID:@"lrclib_manual"];
    [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
    [self close];
}

@end
