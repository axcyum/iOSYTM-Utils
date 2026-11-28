#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "IVLModels.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, IVLTranslationEngine) {
    IVLTranslationEngineApple = 0,             // Apple Translation framework (iOS 18+, on-device)
    IVLTranslationEngineGoogle = 1,            // Google Translate keyless web endpoint
    IVLTranslationEngineAppleIntelligence = 2, // Apple Foundation Models (iOS 26+, Apple Intelligence on-device LLM)
};

/// Availability checks for on-device Apple translation frameworks.
FOUNDATION_EXPORT BOOL IVLIsAppleTranslationAvailable(void);
FOUNDATION_EXPORT BOOL IVLIsAppleIntelligenceAvailable(void);
FOUNDATION_EXPORT NSString *IVLAppleIntelligenceStatusCode(void);

/// Presents the built-in iOS Translation language model download UI (iOS 18+).
FOUNDATION_EXPORT void IVLPresentTranslationModelDownloader(UIViewController *presenter, NSString *targetLang);

/// Translation diagnostic log helpers.
FOUNDATION_EXPORT void IVLTranslatorAppendLog(NSString *message);
FOUNDATION_EXPORT NSString *IVLTranslatorAllLogs(void);
FOUNDATION_EXPORT void IVLTranslatorClearLogs(void);

/// Embedded Apple Intelligence UI assets (icon + top/bottom rainbow glow frame for Settings cell).
FOUNDATION_EXPORT UIImage *_Nullable IVLAppleIntelligenceIconImage(void);
FOUNDATION_EXPORT UIImage *_Nullable IVLAppleIntelligenceGlowImage(void);

/// Multi-engine lyric translator (Apple Translation / Google Translate / Apple Foundation Models).
@interface IVLTranslator : NSObject
+ (instancetype)shared;
/// Fills `line.translation` for every lyric line using the currently selected engine. Completion on main queue.
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
