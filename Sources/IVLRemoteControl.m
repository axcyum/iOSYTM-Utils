#import "IVLRemoteControl.h"
#import "IVLPlaybackManager.h"
#import <MediaPlayer/MediaPlayer.h>
#import <objc/message.h>
#import <objc/runtime.h>

static const void *kIVLHandlersKey = &kIVLHandlersKey;

@implementation IVLRemoteControl

+ (NSMutableArray *)entriesFor:(id)command {
    if (!command) return nil;
    @synchronized (command) {
        NSMutableArray *a = objc_getAssociatedObject(command, kIVLHandlersKey);
        if (!a) { a = [NSMutableArray array]; objc_setAssociatedObject(command, kIVLHandlersKey, a, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
        return a;
    }
}

+ (void)recordHandler:(id)handler forCommand:(id)command {
    if (!handler || !command) return;
    NSMutableArray *a = [self entriesFor:command];
    @synchronized (command) { [a addObject:@{ @"block": [handler copy] }]; }
}

+ (void)recordTarget:(id)target action:(SEL)action forCommand:(id)command {
    if (!target || !action || !command) return;
    NSMutableArray *a = [self entriesFor:command];
    NSValue *weak = [NSValue valueWithNonretainedObject:target];
    @synchronized (command) { [a addObject:@{ @"target": weak, @"action": NSStringFromSelector(action) }]; }
}

/// A best-effort MPRemoteCommandEvent (private initializer) for handlers that inspect the event.
+ (id)eventFor:(MPRemoteCommand *)command {
    Class cls = [MPRemoteCommandEvent class];
    SEL init = NSSelectorFromString(@"initWithCommand:mediaRemoteType:options:");
    if ([cls instancesRespondToSelector:init]) {
        @try { return ((id (*)(id, SEL, id, unsigned int, id))objc_msgSend)([cls alloc], init, command, 0, @{}); }
        @catch (__unused NSException *e) {}
    }
    return nil;
}

+ (BOOL)invoke:(MPRemoteCommand *)command {
    if (!command) return NO;
    NSArray *entries;
    @synchronized (command) { entries = [[self entriesFor:command] copy]; }
    if (!entries.count || !command.enabled) return NO;
    BOOL handled = NO;
    id event = [self eventFor:command];
    void (^run)(void) = ^{};
    for (NSDictionary *e in entries) {
        MPRemoteCommandHandlerStatus (^block)(MPRemoteCommandEvent *) = e[@"block"];
        if (block) {
            run = ^{ block(event); };
        } else {
            id target = [e[@"target"] nonretainedObjectValue];
            SEL action = NSSelectorFromString(e[@"action"]);
            if (![target respondsToSelector:action]) continue;
            run = ^{ ((void (*)(id, SEL, id))objc_msgSend)(target, action, event); };
        }
        @try {
            if (NSThread.isMainThread) run(); else dispatch_sync(dispatch_get_main_queue(), run);
            handled = YES;
        } @catch (__unused NSException *ex) {}
        break;   // the app registers one handler per command; calling all would double-trigger
    }
    return handled;
}

+ (MPRemoteCommandCenter *)center { return [MPRemoteCommandCenter sharedCommandCenter]; }

+ (BOOL)isPlaying {
    MPNowPlayingPlaybackState st = [MPNowPlayingInfoCenter defaultCenter].playbackState;
    if (st == MPNowPlayingPlaybackStatePlaying) return YES;
    if (st == MPNowPlayingPlaybackStatePaused || st == MPNowPlayingPlaybackStateStopped) return NO;
    return [[IVLPlaybackManager shared] isPlaying];
}

+ (BOOL)play { return [self invoke:[self center].playCommand] || (![self isPlaying] && [self invoke:[self center].togglePlayPauseCommand]); }
+ (BOOL)pause { return [self invoke:[self center].pauseCommand] || ([self isPlaying] && [self invoke:[self center].togglePlayPauseCommand]); }
+ (BOOL)togglePlayPause {
    if ([self invoke:[self center].togglePlayPauseCommand]) return YES;
    return [self isPlaying] ? [self pause] : [self play];
}
+ (BOOL)next { return [self invoke:[self center].nextTrackCommand]; }
+ (BOOL)previous { return [self invoke:[self center].previousTrackCommand]; }

@end
