#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface IVLSettingsViewController : UITableViewController
@end

/// Reorderable list of lyrics providers with on/off switches.
@interface IVLProvidersViewController : UITableViewController
@end

@interface IVLLanguagePickerViewController : UITableViewController
+ (NSArray<NSArray<NSString *> *> *)languages;   // @[code, native name]
+ (NSString *)nameForCode:(NSString *)code;
@end

NS_ASSUME_NONNULL_END
