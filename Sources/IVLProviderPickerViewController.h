#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Per-song provider choice (ivLyrics "歌詞プロバイダーを選択").
/// Queries every provider at once, shows what each one found, and pins the picked result to this song.
@interface IVLProviderPickerViewController : UITableViewController
@end

NS_ASSUME_NONNULL_END
