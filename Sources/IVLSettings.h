#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const IVLSettingsDidChangeNotification;

// Keys
extern NSString *const IVLKeyEnabled;            // BOOL
extern NSString *const IVLKeyShowButton;         // BOOL  floating button on Now Playing
extern NSString *const IVLKeyMiniLyric;          // BOOL  current line inside the floating button
extern NSString *const IVLKeyHomeBarLyrics;      // BOOL  live lyrics strip underneath home screen mini player bar
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
extern NSString *const IVLKeyProviderSpicyLyrics;// BOOL
extern NSString *const IVLKeyProviderPetitLyrics;// BOOL
extern NSString *const IVLKeyProviderGenius;     // BOOL
extern NSString *const IVLKeyProviderGitHub;     // BOOL (default NO)
extern NSString *const IVLKeyGitHubLRCRepo;      // NSString (legacy single repo, auto-migrated)
extern NSString *const IVLKeyGitHubLRCBranch;    // NSString (legacy single branch, auto-migrated)
extern NSString *const IVLKeyGitHubLRCRepos;     // NSArray<NSDictionary *> (@{@"repo": @"owner/repo", @"branch": @""})
extern NSString *const IVLKeyProviderOrder;      // NSArray of provider ids, highest priority first
extern NSString *const IVLKeyGlobalOffset;       // NSInteger ms (positive = lyrics earlier)
extern NSString *const IVLKeyAutoResume;         // NSInteger seconds, 0 = never
extern NSString *const IVLKeyButtonX;            // double 0..1
extern NSString *const IVLKeyButtonY;            // double 0..1
extern NSString *const IVLKeySongOffsets;        // NSDictionary videoID -> ms
extern NSString *const IVLKeySongProviders;      // NSDictionary trackKey -> providerID / "lrclib_manual"
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
extern NSString *const IVLKeyImmersivePlayer;    // BOOL  Apple Music full-bleed hero UI (experimental, default NO)
extern NSString *const IVLKeyAMLyrics;           // BOOL  Apple Music inline lyrics view (experimental, default NO)
extern NSString *const IVLKeyCoverFlow;          // BOOL  iOS 6-style landscape Cover Flow (default NO)
extern NSString *const IVLKeyExternalDisplay;    // BOOL  HDMI / AirPlay fullscreen lyrics stage (default NO)
extern NSString *const IVLKeyKaraokeMode;        // BOOL  on-device center vocal removal (default NO)
extern NSString *const IVLKeyKaraokeStrength;    // double 0..100 (default 85)
extern NSString *const IVLKeyVolumeBoost;        // BOOL  soft-clipped volume boost (default NO)
extern NSString *const IVLKeyVolumeBoostLevel;   // double 100..250 (default 150)
extern NSString *const IVLKeyDiscordInterval;    // NSInteger seconds between presence updates (3..60, default 15)
extern NSString *const IVLKeyDiscordStatusDisplay; // NSInteger 0 = Activity Name, 1 = Artist Name, 2 = Song Title
extern NSString *const IVLKeyDiscordName;        // NSString activity name ("Listening to <name>")
extern NSString *const IVLKeyDiscordSongButton;  // BOOL  "Listen on YouTube Music" button
extern NSString *const IVLKeyDiscordGitHubButton;// BOOL  GitHub button
extern NSString *const IVLKeyDiscordGitHubURL;   // NSString
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

+ (nullable NSString *)pinnedProviderForKeys:(NSArray<NSString *> *)keys;
+ (void)setPinnedProvider:(nullable NSString *)providerID forKeys:(NSArray<NSString *> *)keys;

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)githubLRCRepos;
+ (void)setGitHubLRCRepos:(NSArray<NSDictionary<NSString *, NSString *> *> *)repos;

+ (NSString *)defaultTranslationLanguage;

/// Lyrics providers: "youtube", "lyricsplus", "unison", "lyrically", "lrclib"
+ (NSArray<NSString *> *)providerIDs;                 // all known ids in user order
+ (void)setProviderIDs:(NSArray<NSString *> *)ids;
+ (NSArray<NSString *> *)enabledProviderIDs;
+ (NSString *)enableKeyForProvider:(NSString *)pid;
+ (NSString *)nameForProvider:(NSString *)pid;
@end

NS_ASSUME_NONNULL_END
