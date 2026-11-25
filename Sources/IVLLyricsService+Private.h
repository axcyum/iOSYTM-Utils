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

/// Subtitles of the (music) video used as lyrics
@interface IVLLyricsService (Captions)
- (void)captionsForTrack:(IVLTrack *)track completion:(IVLLyricsCompletion)done;
/// All caption tracks [{url, lang, name, asr}] that could be used, plus a label ("字幕"/"動画字幕") or a failure note.
- (void)captionTrackListForTrack:(IVLTrack *)track completion:(void (^)(NSArray<NSDictionary *> *tracks, NSString *_Nullable label, NSString *_Nullable failure))completion;
- (void)fetchCaptionTrack:(NSDictionary *)captionTrack durationMs:(NSInteger)durMs label:(NSString *)label completion:(IVLLyricsCompletion)done;
@end

/// YouTube Music's own lyrics tab (InnerTube)
@interface IVLLyricsService (YouTube)
- (void)youtubeForTrack:(IVLTrack *)track completion:(IVLLyricsCompletion)done;
/// YouTube Music song search (title verified); used when the player's video id is unknown.
- (void)youtubeVideoIDForTrack:(IVLTrack *)track completion:(void (^)(NSString *_Nullable vid))completion;
/// Resolves a borderless 1:1 square album cover URL (googleusercontent) and videoId for Discord RPC.
- (void)youtubeSquareCoverForTrack:(IVLTrack *)track completion:(void (^)(NSString *_Nullable coverURL, NSString *_Nullable vid))completion;
@end

/// Root-level LRC/TTML files hosted in a user-specified GitHub repository
@interface IVLLyricsService (GitHubLRC)
+ (nullable NSString *)parseGitHubOwnerRepo:(NSString *)raw extractedBranch:(NSString *_Nullable *_Nullable)outBranch;
+ (nullable IVLLyrics *)parseLyricsData:(NSData *)data fileName:(NSString *)fileName durationMs:(NSInteger)durMs;
- (void)invalidateGitHubLRCCache;
- (void)githubLRCForTrack:(IVLTrack *)track completion:(IVLLyricsCompletion)done;
- (void)verifyGitHubLRCRepo:(NSString *)raw
                     branch:(nullable NSString *)branch
                 completion:(void (^)(BOOL ok, NSUInteger fileCount, NSString *_Nullable normalizedRepo, NSString *_Nullable errorMsg))completion;
@end

FOUNDATION_EXPORT NSDictionary *_Nullable IVLPickCaptionTrack(NSArray<NSDictionary *> *tracks, IVLTrack *track);

/// Best match among @{ id, title, artist, duration(seconds) } candidates (nil when nothing is convincing).
FOUNDATION_EXPORT NSDictionary *_Nullable IVLBestCandidate(NSArray<NSDictionary *> *candidates, IVLTrack *track);

NS_ASSUME_NONNULL_END
