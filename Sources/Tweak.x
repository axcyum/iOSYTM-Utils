// ivLyrics for YouTube Music — hooks
// Hook points follow dayanch96/YTMusicUltimate (SponsorBlock.x, SeekButtons.x, Settings.x).
// This tweak only reads playback state / metadata and adds a lyrics UI.
// It does not touch ads, Premium checks, downloads or any other app restriction.

%config(generator=internal);

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <MediaPlayer/MediaPlayer.h>
#import "YTMHeaders.h"
#import "IVLPlaybackManager.h"
#import "IVLFloatingButton.h"
#import "IVLLyricsViewController.h"
#import "IVLSettings.h"

static const void *kIVLButtonKey = &kIVLButtonKey;

#pragma mark - Player (track changes, time)

%group Player
%hook YTPlayerViewController

- (void)playbackController:(id)controller didActivateVideo:(id)video withPlaybackData:(id)data {
    %orig;
    [[IVLPlaybackManager shared] playerDidActivateVideo:self];
}

- (void)singleVideo:(id)video currentVideoTimeDidChange:(id)time {
    %orig;
    [[IVLPlaybackManager shared] playerHeartbeat:self];
}

- (void)potentiallyMutatedSingleVideo:(id)video currentVideoTimeDidChange:(id)time {
    %orig;
    [[IVLPlaybackManager shared] playerHeartbeat:self];
}

%end
%end

#pragma mark - System now-playing info (public API, version independent)

%group NowPlayingInfo
%hook MPNowPlayingInfoCenter
- (void)setNowPlayingInfo:(NSDictionary *)info {
    %orig;
    if (self == [MPNowPlayingInfoCenter defaultCenter]) [[IVLPlaybackManager shared] nowPlayingInfoDidChange:info];
}
%end
%end

#pragma mark - Now Playing (floating lyrics button)

%group NowPlaying
%hook YTMNowPlayingViewController

- (void)viewDidLoad {
    %orig;

    IVLFloatingButton *button = [[IVLFloatingButton alloc] initWithFrame:CGRectZero];
    button.hostViewController = self;
    [self.view addSubview:button];
    objc_setAssociatedObject(self, kIVLButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Make sure the manager knows the player even before the first track callback
    YTMWatchViewController *watch = (YTMWatchViewController *)self.parentViewController;
    if ([watch respondsToSelector:@selector(playerViewController)] && ![IVLPlaybackManager shared].player) {
        YTPlayerViewController *player = watch.playerViewController;
        if (player) [[IVLPlaybackManager shared] playerDidActivateVideo:player];
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    IVLFloatingButton *button = objc_getAssociatedObject(self, kIVLButtonKey);
    if (button) {
        [self.view bringSubviewToFront:button];
        [button relayout];
    }
}

%end
%end

#pragma mark - Account menu entry (same place YTMusicUltimate adds its settings)

static UIImage *IVLMenuIcon(void) {
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(24, 24)];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIImage *sym = [[UIImage systemImageNamed:@"quote.bubble"] imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
        [sym drawInRect:CGRectMake(1, 2, 22, 20)];
    }];
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

%group AccountMenu
%hook YTMAvatarAccountView

- (void)setAccountMenuUpperButtons:(id)upper lowerButtons:(id)lower {
    Class buttonClass = %c(YTMAccountButton);
    if (!buttonClass || ![lower isKindOfClass:[NSArray class]]
        || ![buttonClass instancesRespondToSelector:@selector(initWithTitle:identifier:icon:actionBlock:)]) {
        %orig;
        return;
    }
    __weak UIView *weakSelf = self;
    YTMAccountButton *button = [[buttonClass alloc] initWithTitle:@"ivLyrics" identifier:@"ivlyrics" icon:IVLMenuIcon() actionBlock:^(BOOL finished) {
        UIView *view = weakSelf;
        UIViewController *vc = [view respondsToSelector:@selector(_viewControllerForAncestor)] ? [view _viewControllerForAncestor] : nil;
        IVLPresentSettings(vc ?: IVLTopViewController());
    }];
    NSMutableArray *lowerButtons = [lower mutableCopy];
    if (button) [lowerButtons addObject:button];
    %orig(upper, lowerButtons);
}

%end
%end

%ctor {
    @autoreleasepool {
        %init(NowPlayingInfo);
        if (objc_getClass("YTPlayerViewController")) %init(Player);
        if (objc_getClass("YTMNowPlayingViewController")) %init(NowPlaying);
        if (objc_getClass("YTMAvatarAccountView")) %init(AccountMenu);
    }
}
