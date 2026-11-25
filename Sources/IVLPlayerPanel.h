#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Full-screen "Now Playing" sheet in the Apple Music (v27) immersive style:
/// content-as-atmosphere — edge-to-edge artwork dissolving through a progressive blur into a
/// mesh of its own colours, white-only foreground built from opacity tokens, knobless capsule
/// bars, frameless transport, volume bar and a lyrics / AirPlay / queue footer.
@interface IVLPlayerPanel : UIView
@property (nonatomic, copy, nullable) void (^onShowLyrics)(void);
@property (nonatomic, copy, nullable) void (^onClose)(void);     // grabber / swipe down
@property (nonatomic, copy, nullable) void (^onQueue)(void);
@property (nonatomic, strong, nullable) UIMenu *moreMenu;         // "•••"
- (void)setArtwork:(nullable UIImage *)image;
- (void)refresh;   // call every frame while visible
@end

NS_ASSUME_NONNULL_END
