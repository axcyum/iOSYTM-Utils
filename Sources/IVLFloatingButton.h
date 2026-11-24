#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Draggable lyrics button shown on the Now Playing screen.
/// Tap: open lyrics. Long press: settings. Drag: move (position is remembered).
/// Optionally shows the current lyric line next to the icon ("mini lyrics").
@interface IVLFloatingButton : UIView
@property (nonatomic, weak, nullable) UIViewController *hostViewController;
- (void)relayout;
@end

NS_ASSUME_NONNULL_END
