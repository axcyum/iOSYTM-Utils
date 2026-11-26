#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Real-time on-device audio DSP (bass-preserving center vocal removal for Karaoke + soft-clipped Volume Boost).
/// Hooks AudioUnitSetProperty via Mach-O symbol rebinding so it works in sideloaded and jailbroken builds alike.
@interface IVLAudioDSP : NSObject
+ (instancetype)shared;
- (void)start;
@end

NS_ASSUME_NONNULL_END
