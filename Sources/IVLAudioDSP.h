#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

/// Real-time on-device audio DSP (bass-preserving center vocal removal for Karaoke + soft-clipped Volume Boost).
@interface IVLAudioDSP : NSObject
+ (instancetype)shared;
- (void)start;
+ (NSString *)statusText;
+ (void)presentQuickSheetFrom:(UIViewController *)vc;
/// In-place PCM processing hooks called from ObjC audio player hooks.
+ (void)processPCMBuffer:(nullable AVAudioPCMBuffer *)buffer;
+ (void)processSampleBuffer:(nullable CMSampleBufferRef)sampleBuffer;
+ (void)attachTapToPlayerItem:(nullable AVPlayerItem *)item;
@end

NS_ASSUME_NONNULL_END
