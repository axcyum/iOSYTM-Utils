#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface IVLPlayerPanel : UIView
@property (nonatomic, copy, nullable) void (^onShowLyrics)(void);
@property (nonatomic, copy, nullable) void (^onClose)(void);               // grabber / swipe down
@property (nonatomic, copy, nullable) void (^onQueue)(void);
@property (nonatomic, copy, nullable) void (^onOpenProviderPicker)(void);
@property (nonatomic, copy, nullable) void (^onLyricsModeChanged)(void);
@property (nonatomic, strong, nullable) UIMenu *moreMenu;                  // "•••"
@property (nonatomic, readonly) BOOL lyricsMode;                           // dedicated Apple Music inline lyrics mode

- (void)setArtwork:(nullable UIImage *)image;
- (void)setLyricsMode:(BOOL)on animated:(BOOL)animated;
- (void)toggleLyricsMode;
- (void)refresh;   // call every frame while visible
@end

NS_ASSUME_NONNULL_END
