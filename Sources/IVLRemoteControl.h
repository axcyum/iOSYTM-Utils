#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Playback control through the handlers the app registers for lock screen / headphone controls
/// (MPRemoteCommandCenter). The registrations are recorded by the MPRemoteCommand hooks in Tweak.x,
/// so play / pause / next / previous work exactly like the lock screen buttons.
@interface IVLRemoteControl : NSObject
+ (void)recordHandler:(id)handler forCommand:(id)command;
+ (void)recordTarget:(id)target action:(SEL)action forCommand:(id)command;

+ (BOOL)play;
+ (BOOL)pause;
+ (BOOL)togglePlayPause;
+ (BOOL)next;
+ (BOOL)previous;
+ (BOOL)isPlaying;
/// The app's "like" (thumbs up) command, when it registered one for the lock screen.
+ (BOOL)canLike;
+ (BOOL)like;
@end

NS_ASSUME_NONNULL_END
