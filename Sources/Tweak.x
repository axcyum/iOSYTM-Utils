// iOS YTMusic Utilities — hooks
// Hook points follow dayanch96/YTMusicUltimate (SponsorBlock.x, SeekButtons.x, Settings.x).
// This tweak only reads playback state / metadata and adds lyrics & player utilities.
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
#import "IVLLockScreen.h"
#import "IVLDiscord.h"
#import "IVLSpotify.h"
#import "IVLRemoteControl.h"
#import "IVLWebNowPlaying.h"
#import "IVLExtras.h"
#import "IVLScrobbler.h"
#import "IVLCoverFlow.h"
#import "IVLHomeBarLyrics.h"
#import "IVLExternalDisplay.h"
#import "IVLAudioDSP.h"

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

- (void)setPlayerViewLayout:(NSInteger)layout {
    if (layout == 2 && [IVLCoverFlowManager shouldBlockNativeFullscreen]) return;
    %orig;
}

%end
%end

#pragma mark - Cover Flow native landscape fullscreen blocker & real queue capture

%group WatchFullscreenBlock
%hook YTMWatchViewController

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    if ([IVLCoverFlowManager shouldBlockNativeFullscreen]) return UIInterfaceOrientationMaskPortrait;
    return %orig;
}

- (BOOL)shouldAutorotate {
    if ([IVLCoverFlowManager shouldBlockNativeFullscreen]) return NO;
    return %orig;
}

%end
%end

%group PlaylistQueueCapture
%hook YTIPlaylistPanelRenderer

- (id)contentsArray {
    id arr = %orig;
    if ([arr isKindOfClass:[NSArray class]] && [(NSArray *)arr count] > 0) {
        [[IVLCoverFlowManager shared] capturePlaylistPanel:self];
    }
    return arr;
}

%end
%end

#pragma mark - On-device Audio DSP hooks (AVAudioPlayerNode / AVSampleBufferAudioRenderer / AVPlayer)

%group AudioDSPHooks
%hook AVAudioPlayerNode

- (void)scheduleBuffer:(AVAudioPCMBuffer *)buffer completionHandler:(id)completionHandler {
    [IVLAudioDSP processPCMBuffer:buffer];
    %orig;
}

- (void)scheduleBuffer:(AVAudioPCMBuffer *)buffer completionCallbackType:(NSInteger)callbackType completionHandler:(id)completionHandler {
    [IVLAudioDSP processPCMBuffer:buffer];
    %orig;
}

- (void)scheduleBuffer:(AVAudioPCMBuffer *)buffer atTime:(id)when options:(NSUInteger)options completionHandler:(id)completionHandler {
    [IVLAudioDSP processPCMBuffer:buffer];
    %orig;
}

- (void)scheduleBuffer:(AVAudioPCMBuffer *)buffer atTime:(id)when options:(NSUInteger)options completionCallbackType:(NSInteger)callbackType completionHandler:(id)completionHandler {
    [IVLAudioDSP processPCMBuffer:buffer];
    %orig;
}

%end

%hook AVSampleBufferAudioRenderer

- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    [IVLAudioDSP processSampleBuffer:sampleBuffer];
    %orig;
}

%end

%hook AVPlayer

- (void)replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item {
    %orig;
    [IVLAudioDSP attachTapToPlayerItem:item];
}

- (void)play {
    [IVLAudioDSP attachTapToPlayerItem:self.currentItem];
    %orig;
}

%end
%end

#pragma mark - System now-playing info (public API, version independent)

%group NowPlayingInfo
%hook MPNowPlayingInfoCenter
- (void)setNowPlayingInfo:(NSDictionary *)info {
    IVLLockScreen *lock = [IVLLockScreen shared];
    if (self != [MPNowPlayingInfoCenter defaultCenter] || lock.updating) { %orig; return; }
    // lock screen lyrics: forward the app's dictionary with our artwork while lyrics are shown
    %orig([lock processAppInfo:info]);
    [[IVLPlaybackManager shared] nowPlayingInfoDidChange:info];
    NSDictionary *copy = [info copy];
    dispatch_async(dispatch_get_main_queue(), ^{ [[IVLDiscord shared] noteMetadata:copy]; });
}
%end
%end

#pragma mark - Remote commands (record the app's handlers so WebNowPlaying / sleep timer can use them)

%group RemoteCommands
%hook MPRemoteCommand
- (id)addTargetWithHandler:(MPRemoteCommandHandlerStatus (^)(MPRemoteCommandEvent *))handler {
    id token = %orig;
    [IVLRemoteControl recordHandler:handler forCommand:self];
    return token;
}
- (void)addTarget:(id)target action:(SEL)action {
    %orig;
    [IVLRemoteControl recordTarget:target action:action forCommand:self];
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

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    if ([IVLCoverFlowManager shouldBlockNativeFullscreen]) return UIInterfaceOrientationMaskPortrait;
    return %orig;
}

- (BOOL)shouldAutorotate {
    if ([IVLCoverFlowManager shouldBlockNativeFullscreen]) return NO;
    return %orig;
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
    YTMAccountButton *button = [[buttonClass alloc] initWithTitle:@"iOS YTMusic Utilities" identifier:@"ivlyrics" icon:IVLMenuIcon() actionBlock:^(BOOL finished) {
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
        %init(RemoteCommands);
        %init(AudioDSPHooks);
        dispatch_async(dispatch_get_main_queue(), ^{
            [IVLLockScreen shared];
            [IVLSpotify shared];
            [IVLDiscord shared];
            [IVLWebNowPlaying shared];
            [[IVLStats shared] start];
            [IVLSleepTimer shared];
            [[IVLScrobbler shared] start];
            [[IVLCoverFlowManager shared] start];
            [[IVLHomeBarLyricsManager shared] start];
            [[IVLExternalDisplayManager shared] start];
            [[IVLAudioDSP shared] start];
        });
        if (objc_getClass("YTPlayerViewController")) %init(Player);
        if (objc_getClass("YTMWatchViewController")) %init(WatchFullscreenBlock);
        if (objc_getClass("YTIPlaylistPanelRenderer")) %init(PlaylistQueueCapture);
        if (objc_getClass("YTMNowPlayingViewController")) %init(NowPlaying);
        if (objc_getClass("YTMAvatarAccountView")) %init(AccountMenu);
    }
}
