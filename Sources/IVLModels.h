#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A timed word/syllable inside a line (karaoke).
@interface IVLWord : NSObject
@property (nonatomic, copy) NSString *text;       // may contain trailing whitespace
@property (nonatomic, assign) NSInteger startMs;
@property (nonatomic, assign) NSInteger endMs;
+ (instancetype)wordWithText:(NSString *)text start:(NSInteger)start end:(NSInteger)end;
@end

@interface IVLLyricLine : NSObject
@property (nonatomic, assign) NSInteger startMs;
@property (nonatomic, assign) NSInteger endMs;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy, nullable) NSArray<IVLWord *> *words;   // nil = line-level sync only
@property (nonatomic, assign) BOOL instrumental;                    // generated "• • •" break
@property (nonatomic, assign) BOOL alternateVoice;                  // duet: second singer
// Filled lazily
@property (nonatomic, copy, nullable) NSString *translation;
@property (nonatomic, copy, nullable) NSString *pronunciation;
@end

@interface IVLLyrics : NSObject
@property (nonatomic, copy) NSArray<IVLLyricLine *> *lines;
@property (nonatomic, assign) BOOL synced;
@property (nonatomic, assign) BOOL karaoke;
@property (nonatomic, copy) NSString *source;           // "Unison", "LRCLIB", ...
@property (nonatomic, copy, nullable) NSString *language; // detected (BCP-47)
@property (nonatomic, assign) BOOL manual;               // chosen by user search

- (NSInteger)indexOfLineAtTime:(NSInteger)ms;              // -1 before first line
- (NSString *)plainText;

- (NSDictionary *)dictionaryRepresentation;
+ (nullable instancetype)lyricsWithDictionary:(NSDictionary *)dict;
@end

@interface IVLTrack : NSObject
@property (nonatomic, copy) NSString *videoID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, assign) NSTimeInterval duration;   // seconds, 0 = unknown
@property (nonatomic, copy, nullable) NSString *artworkURL;
@property (nonatomic, strong, nullable) id artworkImage;   // UIImage from the system now-playing info
@end

NS_ASSUME_NONNULL_END
