#import <Foundation/Foundation.h>
#import "IVLModels.h"

NS_ASSUME_NONNULL_BEGIN

/// Keyless Google Translate web endpoint (same experimental provider as ivLyrics' Addon_AI_GoogleTranslate).
@interface IVLTranslator : NSObject
+ (instancetype)shared;
/// Fills `line.translation` for every lyric line. Completion on main queue.
- (void)translateLyrics:(IVLLyrics *)lyrics videoID:(NSString *)videoID target:(NSString *)lang
             completion:(void (^)(BOOL success))completion;
- (void)clearCache;
@end

/// Offline pronunciation (romaji / kana / pinyin / romanization) via CFStringTokenizer & ICU transforms.
@interface IVLPronunciation : NSObject
/// mode 1 = Latin, 2 = Hiragana (Japanese only, others fall back to Latin)
+ (nullable NSString *)pronunciationForText:(NSString *)text language:(nullable NSString *)lang mode:(NSInteger)mode;
+ (void)applyToLyrics:(IVLLyrics *)lyrics mode:(NSInteger)mode;
@end

NS_ASSUME_NONNULL_END
