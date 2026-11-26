#import <UIKit/UIKit.h>
#import "IVLLyricsService.h"

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const IVLSpotifyStateDidChangeNotification;

/// "Spotify Lyrics" provider. The user signs in to open.spotify.com in a WKWebView;
/// the web player's own access token is picked up from its requests and used for
/// track search and the color-lyrics endpoint (same data the Spotify apps show).
@interface IVLSpotify : NSObject
+ (instancetype)shared;
@property (nonatomic, assign, readonly) BOOL loggedIn;
@property (nonatomic, copy, readonly) NSString *statusText;
- (void)refreshLoginState;
- (void)lyricsForTrack:(IVLTrack *)track completion:(IVLLyricsCompletion)completion;
/// Resolves Spotify access token and best-matching Spotify track ID for SpicyLyrics.
- (void)resolveTokenAndTrackIDForTrack:(IVLTrack *)track
                            completion:(void (^)(NSString *_Nullable token, NSString *_Nullable trackID, NSError *_Nullable error))completion;
- (UIViewController *)loginViewController;
- (void)logout;
@end

NS_ASSUME_NONNULL_END
