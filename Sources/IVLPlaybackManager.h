#import <UIKit/UIKit.h>
#import "IVLModels.h"

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const IVLTrackDidChangeNotification;
extern NSNotificationName const IVLLyricsDidChangeNotification;   // lyrics, translation or pronunciation updated

typedef NS_ENUM(NSInteger, IVLLyricsState) {
    IVLLyricsStateIdle = 0,
    IVLLyricsStateLoading,
    IVLLyricsStateLoaded,
    IVLLyricsStateNotFound,
    IVLLyricsStateError,
};

@interface IVLPlaybackManager : NSObject
+ (instancetype)shared;

@property (nonatomic, weak, nullable) UIViewController *player;     // YTPlayerViewController
@property (nonatomic, strong, readonly, nullable) IVLTrack *track;
@property (nonatomic, strong, readonly, nullable) IVLLyrics *lyrics;
@property (nonatomic, assign, readonly) IVLLyricsState state;
@property (nonatomic, assign, readonly) BOOL translating;

/// Called from the YTPlayerViewController hook.
- (void)playerDidActivateVideo:(UIViewController *)player;
/// Called from the player's time-change callback (cheap; detects missed track changes).
- (void)playerHeartbeat:(UIViewController *)player;

/// Playback position in ms with global + per-song offset applied.
- (NSInteger)currentTimeMs;
/// Raw player position (no offsets).
- (NSInteger)rawTimeMs;
- (BOOL)isPlaying;
- (void)seekToMs:(NSInteger)ms;   // ms in lyric time (offsets are compensated)

- (NSInteger)songOffsetMs;
- (void)setSongOffsetMs:(NSInteger)ms;

- (void)reloadLyrics;                       // ignore cache
- (void)useManualLyrics:(IVLLyrics *)lyrics;
- (void)refreshExtras;                       // re-apply translation / pronunciation after settings change
- (nullable NSString *)currentLineText;
@end

NS_ASSUME_NONNULL_END
