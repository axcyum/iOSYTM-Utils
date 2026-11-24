#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const IVLDiscordStatusDidChangeNotification;

/// Discord Rich Presence (merged from axcyum/YTMusic-iOS-Presence, GPL-3.0).
/// Needs the official Discord Social SDK at build time (IVL_DISCORD=1) and
/// discord_partner_sdk.framework inside the app at run time.
@interface IVLDiscord : NSObject
+ (instancetype)shared;
/// Compiled with the SDK and the SDK framework is loaded.
+ (BOOL)available;
@property (nonatomic, copy, readonly) NSString *status;
@property (nonatomic, assign, readonly) BOOL linked;     // tokens stored
- (BOOL)enabled;
- (void)login;          // OAuth (PKCE) through the SDK
- (void)retry;          // resume sharing
- (void)disable;        // stop sharing and disconnect
- (void)forget;         // revoke + delete stored tokens
- (BOOL)coverEnabled;
- (void)setCoverEnabled:(BOOL)on;
- (NSArray<NSURL *> *)logFiles;
- (void)noteMetadata:(NSDictionary *)info;   // from the now-playing hook
@end

NS_ASSUME_NONNULL_END
