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
/// Free-text search on LRCLIB for the manual picker.
- (void)searchQuery:(NSString *)query completion:(void (^)(NSArray<IVLSearchResult *> *results, NSError *_Nullable error))completion;

- (void)saveManualLyrics:(IVLLyrics *)lyrics forVideoID:(NSString *)videoID;
- (void)removeCachedLyricsForVideoID:(NSString *)videoID;   // also removes manual choice
- (void)clearCache;
- (unsigned long long)cacheSize;

/// "Song (Official Video)" -> "Song", "Artist - Topic" -> "Artist"
+ (NSString *)cleanTitle:(NSString *)title;
+ (NSString *)cleanArtist:(NSString *)artist;
@end

NS_ASSUME_NONNULL_END
