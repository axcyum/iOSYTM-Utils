#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Real-time on-device audio DSP (bass-preserving center vocal removal for Karaoke + soft-clipped Volume Boost).
/// Hooks AudioUnitSetProperty, AudioUnitRender, and AudioQueueEnqueueBuffer via Mach-O symbol rebinding (__DATA & __DATA_CONST).
@interface IVLAudioDSP : NSObject
+ (instancetype)shared;
- (void)start;
+ (NSString *)statusText;
+ (void)presentQuickSheetFrom:(UIViewController *)vc;
@end

NS_ASSUME_NONNULL_END
