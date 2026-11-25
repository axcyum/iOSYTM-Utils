#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const IVLScrobblerDidChangeNotification;

/// Last.fm and ListenBrainz scrobbling (SimpMusic feature).
/// Now playing is sent when a song starts; a scrobble once half the song or 4 minutes
/// were actually listened to (songs shorter than 30 s are ignored), as Last.fm requires.
/// Failed submissions are queued on disk and retried.
@interface IVLScrobbler : NSObject
+ (instancetype)shared;
- (void)start;
@property (nonatomic, copy, readonly) NSString *lastfmStatus;
@property (nonatomic, copy, readonly) NSString *listenbrainzStatus;
@property (nonatomic, readonly) BOOL lastfmLoggedIn;
@property (nonatomic, readonly) NSUInteger pending;
- (void)lastfmLoginWithUser:(NSString *)user password:(NSString *)password completion:(void (^)(BOOL ok, NSString *message))completion;
- (void)lastfmLogout;
- (void)verifyListenBrainz:(void (^)(BOOL ok, NSString *message))completion;
@end

NS_ASSUME_NONNULL_END
