#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const IVLWebNowPlayingStatusDidChangeNotification;

/// WebNowPlaying client (same protocol as the WebNowPlaying browser extension).
/// Connects to a WebNowPlaying adapter such as WebNowPlaying-Rainmeter (ws://<PC>:8974),
/// streams what is playing and, when allowed, executes play/pause/skip/seek from the adapter.
/// Supports adapter communication revisions legacy, 1, 2 and 3 (libwnp / Rainmeter 3.x).
@interface IVLWebNowPlaying : NSObject
+ (instancetype)shared;
@property (nonatomic, copy, readonly) NSString *status;
- (void)reconnect;   // after settings changes
@end

NS_ASSUME_NONNULL_END
