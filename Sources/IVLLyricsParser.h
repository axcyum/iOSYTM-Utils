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

/// Shared post-processing for providers that return structured JSON lines
/// (sort, end times, word end times, instrumental breaks).
+ (nullable IVLLyrics *)lyricsWithTimedLines:(NSMutableArray<IVLLyricLine *> *)lines durationMs:(NSInteger)durationMs explicitEnds:(BOOL)explicitEnds;
/// Collapses whitespace inside/between words, trims the edges, drops empty words and
/// returns the joined line text (so karaoke character ranges match the drawn string).
+ (NSString *)normalizeWords:(NSMutableArray<IVLWord *> *)words;
@end

NS_ASSUME_NONNULL_END
