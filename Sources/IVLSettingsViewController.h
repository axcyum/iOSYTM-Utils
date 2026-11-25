#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface IVLSettingsViewController : UITableViewController
/// nil = main page, "lock", "spotify", "discord"
- (instancetype)initWithPage:(nullable NSString *)page;
@end

/// Reorderable list of lyrics providers with on/off switches.
@interface IVLProvidersViewController : UITableViewController
@end

@interface IVLLanguagePickerViewController : UITableViewController
/// Default: translation target. Pass IVLKeyCaptionLang for the subtitle language (adds "Automatic").
@property (nonatomic, copy) NSString *settingsKey;
+ (NSArray<NSArray<NSString *> *> *)languages;   // @[code, native name]
+ (NSString *)nameForCode:(NSString *)code;
@end

NS_ASSUME_NONNULL_END
