#import "IVLRecognizer.h"
#import "IVLRemoteControl.h"
#import "IVLLyricsService+Private.h"
#import "IVLLyricsViewController.h"
#import "IVLLocalization.h"
#import <AVFoundation/AVFoundation.h>
#import <ShazamKit/ShazamKit.h>

BOOL IVLOpenInYouTubeMusic(NSURL *url) {
    if (!url) return NO;
    NSUserActivity *activity = [[NSUserActivity alloc] initWithActivityType:NSUserActivityTypeBrowsingWeb];
    activity.webpageURL = url;
    UIApplication *app = UIApplication.sharedApplication;
    // scene-based apps route universal links through the scene delegate
    for (UIScene *scene in app.connectedScenes) {
        id<UISceneDelegate> d = scene.delegate;
        if ([d respondsToSelector:@selector(scene:continueUserActivity:)]) {
            [(id<UIWindowSceneDelegate>)d scene:scene continueUserActivity:activity];
            return YES;
        }
    }
    id<UIApplicationDelegate> ad = app.delegate;
    if ([ad respondsToSelector:@selector(application:continueUserActivity:restorationHandler:)]) {
        return [ad application:app continueUserActivity:activity restorationHandler:^(NSArray *r) {}];
    }
    if ([ad respondsToSelector:@selector(application:openURL:options:)]) {
        return [ad application:app openURL:url options:@{}];
    }
    return NO;
}

@interface IVLRecognizerViewController () <SHSessionDelegate>
@end

@implementation IVLRecognizerViewController {
    SHSession *_session;
    AVAudioEngine *_engine;
    UILabel *_status;
    UIImageView *_cover;
    UILabel *_title, *_artist;
    UIButton *_play, *_again;
    UIView *_pulse;
    NSTimer *_timeout;
    SHMediaItem *_match;
    BOOL _wasPlaying;
    NSString *_prevCategory;
    AVAudioSessionMode _prevMode;
    AVAudioSessionCategoryOptions _prevOptions;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = IVLLoc(@"recognize");
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];

    _pulse = [UIView new];
    _pulse.backgroundColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.25];
    _pulse.layer.cornerRadius = 70;
    _cover = [UIImageView new];
    _cover.contentMode = UIViewContentModeScaleAspectFill;
    _cover.clipsToBounds = YES;
    _cover.layer.cornerRadius = 16;
    _cover.image = [UIImage systemImageNamed:@"waveform" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:56 weight:UIImageSymbolWeightSemibold]];
    _cover.tintColor = UIColor.systemBlueColor;
    _cover.contentMode = UIViewContentModeCenter;
    _status = [UILabel new];
    _status.textAlignment = NSTextAlignmentCenter;
    _status.numberOfLines = 0;
    _status.textColor = UIColor.secondaryLabelColor;
    _title = [UILabel new];
    _title.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
    _title.textAlignment = NSTextAlignmentCenter;
    _title.numberOfLines = 2;
    _artist = [UILabel new];
    _artist.font = [UIFont systemFontOfSize:18 weight:UIFontWeightMedium];
    _artist.textColor = UIColor.secondaryLabelColor;
    _artist.textAlignment = NSTextAlignmentCenter;

    UIButtonConfiguration *pc = [UIButtonConfiguration filledButtonConfiguration];
    pc.title = IVLLoc(@"recognize_play");
    pc.image = [UIImage systemImageNamed:@"play.fill"];
    pc.imagePadding = 8;
    pc.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    _play = [UIButton buttonWithConfiguration:pc primaryAction:[UIAction actionWithHandler:^(UIAction *a) { [self playMatch]; }]];
    _play.hidden = YES;
    UIButtonConfiguration *ac = [UIButtonConfiguration grayButtonConfiguration];
    ac.title = IVLLoc(@"recognize_again");
    ac.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    _again = [UIButton buttonWithConfiguration:ac primaryAction:[UIAction actionWithHandler:^(UIAction *a) { [self startListening]; }]];
    _again.hidden = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_cover, _title, _artist, _status, _play, _again]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 14;
    [stack setCustomSpacing:28 afterView:_cover];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    _pulse.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_pulse];
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:24],
        [_cover.widthAnchor constraintEqualToConstant:180],
        [_cover.heightAnchor constraintEqualToConstant:180],
        [_pulse.centerXAnchor constraintEqualToAnchor:_cover.centerXAnchor],
        [_pulse.centerYAnchor constraintEqualToAnchor:_cover.centerYAnchor],
        [_pulse.widthAnchor constraintEqualToConstant:140],
        [_pulse.heightAnchor constraintEqualToConstant:140],
        [_play.widthAnchor constraintGreaterThanOrEqualToConstant:220],
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!_session) [self startListening];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopListening];
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)setStatusText:(NSString *)s { dispatch_async(dispatch_get_main_queue(), ^{ self->_status.text = s; }); }

- (void)startListening {
    _match = nil;
    _play.hidden = YES;
    _again.hidden = YES;
    _title.text = nil;
    _artist.text = nil;
    _cover.image = [UIImage systemImageNamed:@"waveform" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:56 weight:UIImageSymbolWeightSemibold]];
    _cover.contentMode = UIViewContentModeCenter;
    [AVAudioSession.sharedInstance requestRecordPermission:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!granted) { self->_status.text = IVLLoc(@"recognize_mic_denied"); self->_again.hidden = NO; return; }
            [self beginCapture];
        });
    }];
}

- (void)beginCapture {
    // the music in this app would be recognised instead of the room: pause it while listening
    _wasPlaying = [IVLRemoteControl isPlaying];
    if (_wasPlaying) [IVLRemoteControl pause];

    AVAudioSession *as = AVAudioSession.sharedInstance;
    _prevCategory = as.category;
    _prevMode = as.mode;
    _prevOptions = as.categoryOptions;
    NSError *err = nil;
    [as setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeMeasurement options:AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionMixWithOthers error:&err];
    [as setActive:YES error:&err];

    _session = [SHSession new];
    _session.delegate = self;
    _engine = [AVAudioEngine new];
    AVAudioInputNode *input = _engine.inputNode;
    AVAudioFormat *fmt = [input outputFormatForBus:0];
    SHSession *session = _session;
    [input installTapOnBus:0 bufferSize:4096 format:fmt block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        [session matchStreamingBuffer:buffer atTime:when];
    }];
    [_engine prepare];
    if (![_engine startAndReturnError:&err]) {
        _status.text = [NSString stringWithFormat:@"%@\n%@", IVLLoc(@"recognize_failed"), err.localizedDescription ?: @""];
        _again.hidden = NO;
        [self stopListening];
        return;
    }
    _status.text = IVLLoc(@"recognize_listening");
    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    pulse.fromValue = @0.8; pulse.toValue = @1.5; pulse.duration = 1.1; pulse.repeatCount = HUGE_VALF; pulse.autoreverses = YES;
    [_pulse.layer addAnimation:pulse forKey:@"p"];
    [_timeout invalidate];
    _timeout = [NSTimer scheduledTimerWithTimeInterval:15 repeats:NO block:^(NSTimer *t) {
        [self stopListening];
        self->_status.text = IVLLoc(@"recognize_none");
        self->_again.hidden = NO;
    }];
}

- (void)stopListening {
    [_timeout invalidate];
    _timeout = nil;
    [_pulse.layer removeAllAnimations];
    if (_engine) {
        [_engine.inputNode removeTapOnBus:0];
        [_engine stop];
        _engine = nil;
    }
    _session.delegate = nil;
    _session = nil;
    if (_prevCategory) {
        [AVAudioSession.sharedInstance setCategory:_prevCategory mode:_prevMode options:_prevOptions error:nil];
        _prevCategory = nil;
    }
}

#pragma mark SHSessionDelegate

- (void)session:(SHSession *)session didFindMatch:(SHMatch *)match {
    SHMediaItem *item = match.mediaItems.firstObject;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self stopListening];
        self->_match = item;
        self->_title.text = item.title ?: @"?";
        self->_artist.text = item.artist;
        self->_status.text = IVLLoc(@"recognize_found");
        self->_play.hidden = NO;
        self->_again.hidden = NO;
        [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
        if (item.artworkURL) {
            IVLLoadImage(item.artworkURL.absoluteString, ^(UIImage *img) {
                if (!img) return;
                self->_cover.contentMode = UIViewContentModeScaleAspectFill;
                self->_cover.image = img;
            });
        }
    });
}

- (void)session:(SHSession *)session didNotFindMatchForSignature:(SHSignature *)signature error:(NSError *)error {
    if (!error) return;   // no match yet: keep listening until the timeout
    dispatch_async(dispatch_get_main_queue(), ^{
        [self stopListening];
        // ShazamKit needs the ShazamKit app service on the signing identity; sideloaded builds may not have it
        self->_status.text = [NSString stringWithFormat:@"%@\n%@", IVLLoc(@"recognize_failed"), error.localizedDescription ?: @""];
        self->_again.hidden = NO;
    });
}

#pragma mark Play in YouTube Music

- (void)playMatch {
    SHMediaItem *item = _match;
    if (!item.title.length) return;
    IVLTrack *t = [IVLTrack new];
    t.title = item.title;
    t.artist = item.artist ?: @"";
    _status.text = IVLLoc(@"loading");
    [[IVLLyricsService shared] youtubeVideoIDForTrack:t completion:^(NSString *vid) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSURL *url;
            if (vid.length == 11) {
                url = [NSURL URLWithString:[NSString stringWithFormat:@"https://music.youtube.com/watch?v=%@", vid]];
            } else {
                NSURLComponents *c = [NSURLComponents componentsWithString:@"https://music.youtube.com/search"];
                c.queryItems = @[[NSURLQueryItem queryItemWithName:@"q" value:[NSString stringWithFormat:@"%@ %@", item.title, item.artist ?: @""]]];
                url = c.URL;
            }
            UIViewController *presenter = self.presentingViewController;
            [self dismissViewControllerAnimated:YES completion:^{
                if (!IVLOpenInYouTubeMusic(url)) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
                (void)presenter;
            }];
        });
    }];
}

@end
