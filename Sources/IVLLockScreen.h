#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>

NS_ASSUME_NONNULL_BEGIN

/// Lock screen / Control Center lyrics (merged from LockLyrics).
/// Renders the current lyric into the now-playing artwork using the shared lyrics engine
/// (all providers, offsets, translation) with lead time, slide+fade transitions and karaoke fill.
@interface IVLLockScreen : NSObject
+ (instancetype)shared;

/// Called from the setNowPlayingInfo: hook with the app's own dictionary.
/// Returns the dictionary to forward (artwork replaced while lyrics are shown).
- (nullable NSDictionary *)processAppInfo:(nullable NSDictionary *)info;
/// YES while we push our own artwork (the hook must pass it straight through).
@property (nonatomic, assign, readonly) BOOL updating;
/// The last dictionary the app itself set (never contains our artwork).
@property (nonatomic, copy, readonly, nullable) NSDictionary *originalInfo;
- (BOOL)isRenderedArtwork:(nullable id)artwork;
@end

NS_ASSUME_NONNULL_END
