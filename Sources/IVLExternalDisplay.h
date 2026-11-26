#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Displays an Apple TV-style 16:9 fullscreen lyrics & artwork stage on HDMI / AirPlay displays,
/// plus a quick sheet with AirPlay picker and on-device Fullscreen TV Stage for Screen Mirroring.
@interface IVLExternalDisplayManager : NSObject
+ (instancetype)shared;
- (void)start;
+ (NSString *)statusText;
+ (BOOL)isConnected;
+ (void)presentQuickSheetFrom:(UIViewController *)vc;
+ (void)presentFullscreenStageFrom:(UIViewController *)vc;
@end

NS_ASSUME_NONNULL_END
