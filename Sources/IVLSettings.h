#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const IVLSettingsDidChangeNotification;

// Keys
extern NSString *const IVLKeyEnabled;            // BOOL
extern NSString *const IVLKeyShowButton;         // BOOL  floating button on Now Playing
extern NSString *const IVLKeyMiniLyric;          // BOOL  current line inside the floating button
extern NSString *const IVLKeyKeepAwake;          // BOOL
extern NSString *const IVLKeyFontSize;           // double (pt)
extern NSString *const IVLKeyAlignment;          // 0 = left, 1 = center
extern NSString *const IVLKeyKaraoke;            // BOOL  word-by-word fill
extern NSString *const IVLKeyShowBreaks;         // BOOL  instrumental "• • •"
extern NSString *const IVLKeyBackground;         // 0 = artwork blur, 1 = solid
extern NSString *const IVLKeyTranslation;        // BOOL
extern NSString *const IVLKeyTranslationLang;    // NSString (BCP-47, e.g. "ja")
extern NSString *const IVLKeyPronunciation;      // 0 = off, 1 = romaji/latin, 2 = kana (Japanese)
extern NSString *const IVLKeyProviderUnison;     // BOOL
extern NSString *const IVLKeyProviderLRCLIB;     // BOOL
extern NSString *const IVLKeyProviderYouTube;    // BOOL
extern NSString *const IVLKeyProviderLyricsPlus; // BOOL
extern NSString *const IVLKeyProviderLyrically;  // BOOL
extern NSString *const IVLKeyProviderOrder;      // NSArray of provider ids, highest priority first
extern NSString *const IVLKeyGlobalOffset;       // NSInteger ms (positive = lyrics earlier)
extern NSString *const IVLKeyAutoResume;         // NSInteger seconds, 0 = never
extern NSString *const IVLKeyButtonX;            // double 0..1
extern NSString *const IVLKeyButtonY;            // double 0..1
extern NSString *const IVLKeySongOffsets;        // NSDictionary videoID -> ms

@interface IVLSettings : NSObject
+ (id _Nullable)objectForKey:(NSString *)key;
+ (BOOL)boolForKey:(NSString *)key;
+ (NSInteger)integerForKey:(NSString *)key;
+ (double)doubleForKey:(NSString *)key;
+ (void)setObject:(id _Nullable)value forKey:(NSString *)key;
+ (void)setBool:(BOOL)value forKey:(NSString *)key;

+ (NSInteger)songOffsetForVideoID:(NSString *)videoID;
+ (void)setSongOffset:(NSInteger)ms forVideoID:(NSString *)videoID;

+ (NSString *)defaultTranslationLanguage;

/// Lyrics providers: "youtube", "lyricsplus", "unison", "lyrically", "lrclib"
+ (NSArray<NSString *> *)providerIDs;                 // all known ids in user order
+ (void)setProviderIDs:(NSArray<NSString *> *)ids;
+ (NSArray<NSString *> *)enabledProviderIDs;
+ (NSString *)enableKeyForProvider:(NSString *)pid;
+ (NSString *)nameForProvider:(NSString *)pid;
@end

NS_ASSUME_NONNULL_END
