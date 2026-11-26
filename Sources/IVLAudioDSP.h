#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

/// Real-time on-device audio DSP (band-isolated center vocal removal for Karaoke + soft-clipped Volume Boost).
@interface IVLAudioDSP : NSObject
+ (instancetype)shared;
- (void)start;
+ (NSString *)statusText;
+ (void)presentQuickSheetFrom:(UIViewController *)vc;

/// Renderer volume tracking & amplification hooks
+ (void)registerRenderer:(nullable id)renderer;
+ (float)scaledVolumeForRenderer:(nullable id)renderer requestedVolume:(float)volume;
+ (void)noteRendererFailure:(int)errCode;

/// In-place / decoded PCM processing hooks
+ (void)processPCMBuffer:(nullable AVAudioPCMBuffer *)buffer;
+ (nullable CMSampleBufferRef)createProcessedSampleBuffer:(nullable CMSampleBufferRef)sampleBuffer CF_RETURNS_RETAINED;
+ (void)resetDecoder;
+ (void)attachTapToPlayerItem:(nullable AVPlayerItem *)item;
@end

NS_ASSUME_NONNULL_END
