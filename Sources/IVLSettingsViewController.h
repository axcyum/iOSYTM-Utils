#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface IVLSettingsViewController : UITableViewController
@end

@interface IVLLanguagePickerViewController : UITableViewController
+ (NSArray<NSArray<NSString *> *> *)languages;   // @[code, native name]
+ (NSString *)nameForCode:(NSString *)code;
@end

NS_ASSUME_NONNULL_END
