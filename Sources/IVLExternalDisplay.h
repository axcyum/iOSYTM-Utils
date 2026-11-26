#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Displays an Apple TV-style fullscreen lyrics & artwork stage on connected HDMI or AirPlay displays.
@interface IVLExternalDisplayManager : NSObject
+ (instancetype)shared;
- (void)start;
@end

NS_ASSUME_NONNULL_END
