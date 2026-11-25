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
extern NSString *const IVLKeyLockEnabled;        // BOOL  lyrics on the lock screen artwork
extern NSString *const IVLKeyLockAnimation;      // BOOL  slide + fade between lines
extern NSString *const IVLKeyLockKaraoke;        // BOOL  word fill on the lock screen
extern NSString *const IVLKeyLockTranslation;    // BOOL  pronunciation / translation under the line
extern NSString *const IVLKeyLockLead;           // NSInteger ms shown early (lock screen latency)
extern NSString *const IVLKeyProviderSpotify;    // BOOL
extern NSString *const IVLKeyProviderCaptions;   // BOOL
extern NSString *const IVLKeyWNPEnabled;         // BOOL  WebNowPlaying client
extern NSString *const IVLKeyWNPHost;            // NSString  PC address
extern NSString *const IVLKeyWNPPort;            // NSInteger (8974)
extern NSString *const IVLKeyWNPControl;         // BOOL  accept play/pause/skip/seek from the adapter
extern NSString *const IVLKeyStatsEnabled;       // BOOL  on-device listening statistics
extern NSString *const IVLKeyAccentColor;        // NSString hex, "" = white
extern NSString *const IVLKeyBackgroundColor;    // NSString hex for the solid background
extern NSString *const IVLKeyLastfmEnabled;      // BOOL
extern NSString *const IVLKeyLastfmKey;          // NSString API key (the shared secret lives in the keychain)
extern NSString *const IVLKeyLastfmUser;         // NSString user name after login
extern NSString *const IVLKeyListenBrainzEnabled;// BOOL
extern NSString *const IVLKeyOpenPlayer;         // BOOL  lyrics screen opens on the player page
extern NSString *const IVLKeyCaptionLang;        // NSString, "" = automatic (song language)

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
