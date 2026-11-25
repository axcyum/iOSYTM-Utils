#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// "Recognise the song playing near you" (SimpMusic feature) with Apple's ShazamKit.
/// Listens through the microphone, shows the match and opens it in YouTube Music.
@interface IVLRecognizerViewController : UIViewController
@end

/// Opens a YouTube Music URL inside the app itself (as a universal link), e.g. a watch or search URL.
BOOL IVLOpenInYouTubeMusic(NSURL *url);

NS_ASSUME_NONNULL_END
