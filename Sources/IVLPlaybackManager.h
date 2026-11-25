#import <UIKit/UIKit.h>
#import "IVLModels.h"

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const IVLTrackDidChangeNotification;
extern NSNotificationName const IVLArtworkDidChangeNotification;  // artworkImage arrived or upgraded for current track
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
/// Called from the MPNowPlayingInfoCenter hook (any thread).
- (void)nowPlayingInfoDidChange:(nullable NSDictionary *)info;
/// Re-check sources now (called when the lyrics UI opens).
- (void)refreshNow;
/// Force an immediate re-check of all artwork sources for the current track.
- (void)ensureArtworkNow;
- (NSString *)diagnostics;

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

@interface IVLPlaybackManager (Captions)
/// Caption tracks of the video loaded in the player: [{url, lang, name, asr}] (main thread).
- (NSArray<NSDictionary *> *)currentCaptionTracks;
/// Video id loaded in the player if it is `track` (title or length agree), otherwise nil.
- (nullable NSString *)captionVideoIDForTrack:(IVLTrack *)track;
@end

NS_ASSUME_NONNULL_END
