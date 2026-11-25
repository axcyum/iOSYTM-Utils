#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Apple Music-style player page (SimpMusic's redesigned player): big artwork that shrinks
/// while paused, title, scrubber, previous / play-pause / next and the current lyric line.
@interface IVLPlayerPanel : UIView
@property (nonatomic, copy, nullable) void (^onShowLyrics)(void);
- (void)setArtwork:(nullable UIImage *)image;
- (void)refresh;   // call every frame while visible
@end

NS_ASSUME_NONNULL_END
