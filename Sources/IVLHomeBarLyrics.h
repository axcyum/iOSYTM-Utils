#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Displays a slim live-lyrics bar directly underneath YouTube Music's home-screen mini player bar,
/// matching its exact background color. Toggles live without requiring an app restart.
@interface IVLHomeBarLyricsManager : NSObject
+ (instancetype)shared;
- (void)start;
@end

NS_ASSUME_NONNULL_END
