#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const IVLSleepTimerDidChangeNotification;

/// Sleep timer (from SimpMusic): pause after a number of minutes or at the end of the current song.
@interface IVLSleepTimer : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) BOOL active;
@property (nonatomic, readonly) BOOL endOfTrack;
@property (nonatomic, readonly, nullable) NSDate *fireDate;
- (void)startMinutes:(NSInteger)minutes;
- (void)startEndOfTrack;
- (void)cancel;
- (NSString *)statusText;
@end

/// On-device listening statistics (from SimpMusic's analytics). Nothing leaves the device.
@interface IVLStats : NSObject
+ (instancetype)shared;
- (void)start;                                   // begins recording (main thread)
- (NSDictionary *)summaryForDays:(NSInteger)days; // days <= 0: all time
- (void)reset;
@end

@interface IVLStatsViewController : UITableViewController
@end

@interface IVLSleepTimerViewController : UITableViewController
@end

/// Theme colours for the lyrics screen (SimpMusic-style themes).
@interface IVLTheme : NSObject
/// 0 artwork blur, 1 solid custom colour, 2 artwork colour gradient, 3 AMOLED black
+ (NSInteger)style;
+ (UIColor *)accentColor;                // highlight colour of the active line
+ (UIColor *)customBackgroundColor;
+ (void)dominantColorsOfImage:(UIImage *)image completion:(void (^)(UIColor *top, UIColor *bottom))completion;
+ (NSArray<NSArray *> *)presetColors;    // @[name, hex]
+ (UIColor *)colorFromHex:(NSString *)hex;
@end

/// Renders lyric lines over the blurred artwork as a square image for sharing (SimpMusic "share lyrics as image").
UIImage *IVLLyricsShareImage(NSArray<NSString *> *lines, NSString *_Nullable translation, NSString *title, NSString *artist, UIImage *_Nullable artwork);

NS_ASSUME_NONNULL_END
