#import "IVLLyricsService.h"

NS_ASSUME_NONNULL_BEGIN

@interface IVLLyricsService (Private)
- (void)getJSON:(NSURL *)url completion:(void (^)(id _Nullable json, NSInteger status, NSError *_Nullable error))completion;
+ (NSURL *)URLWithBase:(NSString *)base path:(NSString *)path query:(NSDictionary<NSString *, NSString *> *)query;
+ (NSArray<NSString *> *)artistCandidates:(NSString *)artist;
@end

/// Providers ported from ivLyrics' Addon_Lyrics_LyricsPlus.js and Addon_Lyrics_Paxsenix.js
@interface IVLLyricsService (ExtraProviders)
- (void)lyricsPlusForTrack:(IVLTrack *)track completion:(IVLLyricsCompletion)done;
- (void)lyricallyForTrack:(IVLTrack *)track completion:(IVLLyricsCompletion)done;
@end

/// YouTube Music's own lyrics tab (InnerTube)
@interface IVLLyricsService (YouTube)
- (void)youtubeForTrack:(IVLTrack *)track completion:(IVLLyricsCompletion)done;
@end

NS_ASSUME_NONNULL_END
