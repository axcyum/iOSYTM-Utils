// Private YouTube Music interfaces (reference: dayanch96/YTMusicUltimate Source/Headers).
// Only declarations — never reference these classes directly (no link-time symbols);
// use NSClassFromString / %c() and respondsToSelector: checks.
#import <UIKit/UIKit.h>

@interface YTIThumbnailDetails_Thumbnail : NSObject
@property (nonatomic, copy, readwrite) NSString *URL;
@property (nonatomic, assign, readwrite) unsigned int width;
@end

@interface YTIThumbnailDetails : NSObject
@property (nonatomic, strong, readwrite) NSMutableArray *thumbnailsArray;
@end

@interface YTIVideoDetails : NSObject
@property (nonatomic, copy, readwrite) NSString *videoId;
@property (nonatomic, copy, readwrite) NSString *title;
@property (nonatomic, copy, readwrite) NSString *author;
@property (nonatomic, strong, readwrite) YTIThumbnailDetails *thumbnail;
@end

@interface YTIPlayerResponse : NSObject
@property (nonatomic, assign, readonly) YTIVideoDetails *videoDetails;
@end

@interface YTPlayerResponse : NSObject
@property (nonatomic, assign, readonly) YTIPlayerResponse *playerData;
@end

@interface YTPlayerViewController : UIViewController
@property (nonatomic, assign, readonly) YTPlayerResponse *playerResponse;
@property (readonly, nonatomic) NSString *contentVideoID;
@property (nonatomic, assign, readonly) CGFloat currentVideoTotalMediaTime;
- (void)seekToTime:(CGFloat)time;
- (NSString *)currentVideoID;
- (CGFloat)currentVideoMediaTime;
@end

@interface YTMWatchViewController : UIViewController
@property (nonatomic, weak, readwrite) YTPlayerViewController *playerViewController;
@end

@interface YTMNowPlayingViewController : UIViewController
@end

@interface YTMAccountButton : UIButton
- (id)initWithTitle:(id)title identifier:(id)identifier icon:(id)icon actionBlock:(void (^)(BOOL finished))block;
@end

@interface YTMAvatarAccountView : UIView
@end

@interface UIView (IVLPrivate)
- (UIViewController *)_viewControllerForAncestor;
@end
