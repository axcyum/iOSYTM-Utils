#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// iOS 6-style 3D Cover Flow overlay triggered automatically in landscape when enabled in settings.
@interface IVLCoverFlowManager : NSObject
+ (instancetype)shared;
- (void)start;
/// YES when Cover Flow is enabled in settings (used by hooks to block YouTube Music's forced landscape fullscreen).
+ (BOOL)shouldBlockNativeFullscreen;
@end

NS_ASSUME_NONNULL_END
