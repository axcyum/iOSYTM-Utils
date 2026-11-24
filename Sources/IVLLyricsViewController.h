#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface IVLLyricsViewController : UIViewController
+ (void)presentFromViewController:(UIViewController *)presenter;
@end

/// Shared helpers
void IVLLoadImage(NSString *_Nullable url, void (^completion)(UIImage *_Nullable image));
void IVLPresentSettings(UIViewController *presenter);
UIViewController *_Nullable IVLTopViewController(void);

NS_ASSUME_NONNULL_END
