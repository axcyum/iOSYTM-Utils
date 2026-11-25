#import <Foundation/Foundation.h>
#import "IVLModels.h"

NS_ASSUME_NONNULL_BEGIN

@interface IVLSearchResult : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy, nullable) NSString *album;
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, assign) BOOL synced;
@property (nonatomic, copy) NSString *source;
@property (nonatomic, strong) IVLLyrics *lyrics;
@end

typedef void (^IVLLyricsCompletion)(IVLLyrics *_Nullable lyrics, NSError *_Nullable error);

@interface IVLLyricsService : NSObject
+ (instancetype)shared;

/// Cache -> manual override -> providers (Unison / LRCLIB in configured order).
- (void)lyricsForTrack:(IVLTrack *)track completion:(IVLLyricsCompletion)completion;
/// Runs a single provider (also when disabled in settings). Completion on main queue.
- (void)fetchProvider:(NSString *)providerID track:(IVLTrack *)track completion:(IVLLyricsCompletion)completion;
/// Free-text search on LRCLIB for the manual picker.
- (void)searchQuery:(NSString *)query completion:(void (^)(NSArray<IVLSearchResult *> *results, NSError *_Nullable error))completion;

+ (NSArray<NSString *> *)storageKeysForTrack:(nullable IVLTrack *)track;

- (void)saveManualLyrics:(IVLLyrics *)lyrics forTrack:(IVLTrack *)track providerID:(nullable NSString *)providerID;
- (void)saveManualLyrics:(IVLLyrics *)lyrics forVideoID:(NSString *)videoID;
- (void)removeCachedLyricsForTrack:(IVLTrack *)track;       // clears auto-cache only (preserves saved manual/provider choice)
- (void)clearManualChoiceForTrack:(IVLTrack *)track;        // removes saved manual lyrics & pinned provider for track
- (void)removeCachedLyricsForVideoID:(NSString *)videoID;
- (void)clearCache;
- (unsigned long long)cacheSize;

/// "Song (Official Video)" -> "Song", "Artist - Topic" -> "Artist"
+ (NSString *)cleanTitle:(NSString *)title;
+ (NSString *)cleanArtist:(NSString *)artist;
@end

NS_ASSUME_NONNULL_END
