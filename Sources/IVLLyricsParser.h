#import <Foundation/Foundation.h>
#import "IVLModels.h"

NS_ASSUME_NONNULL_BEGIN

/// Port of ivLyrics' LRC / enhanced-LRC / TTML / plain parsers.
@interface IVLLyricsParser : NSObject
/// Standard & enhanced (A2, `<mm:ss.xx>` word tags) LRC. Returns nil when no timed line exists.
+ (nullable IVLLyrics *)parseLRC:(NSString *)lrc durationMs:(NSInteger)durationMs;
/// Apple-style TTML (line or word timing). Returns nil when no timed line exists.
+ (nullable IVLLyrics *)parseTTML:(NSString *)ttml durationMs:(NSInteger)durationMs;
/// Unsynced lyrics.
+ (nullable IVLLyrics *)parsePlain:(NSString *)text;
@end

NS_ASSUME_NONNULL_END
