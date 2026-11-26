#import "IVLAudioDSP.h"
#import "IVLSettings.h"
#import "IVLLocalization.h"
#import <AudioToolbox/AudioToolbox.h>
#import <MediaToolbox/MediaToolbox.h>
#import <objc/runtime.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <math.h>
#import <string.h>
#import <pthread.h>

// Real-time lock-free DSP parameters (updated on main thread, read in audio render thread)
static _Atomic BOOL gKaraokeOn = NO;
static _Atomic float gKaraokeStrength = 0.85f;
static _Atomic BOOL gBoostOn = NO;
static _Atomic float gBoostGain = 1.5f;
static _Atomic uint64_t gProcessedCalls = 0;
static _Atomic int gActivePath = 0; // 1=RenderCB, 2=AudioUnitRender, 3=AudioQueue
static _Atomic int gRebindHits = 0;

typedef struct {
    AudioUnit unit;
    AURenderCallback origProc;
    void *origRefCon;
    float lpState;
} IVLUnitEntry;

#define kIVLMaxUnits 32
static IVLUnitEntry gUnits[kIVLMaxUnits];
static pthread_mutex_t gUnitsLock = PTHREAD_MUTEX_INITIALIZER;
static float gGlobalLPState = 0.0f;

static inline float IVLSoftClip(float x) {
    if (x > 0.85f) return 0.85f + 0.15f * tanhf((x - 0.85f) / 0.15f);
    if (x < -0.85f) return -0.85f + 0.15f * tanhf((x + 0.85f) / 0.15f);
    return x;
}

static void IVLProcessAudioBufferList(AudioBufferList *ioData, UInt32 inNumberFrames, float *lpPtr, int pathID) {
    if (!ioData || ioData->mNumberBuffers == 0 || inNumberFrames == 0) return;

    atomic_fetch_add_explicit(&gProcessedCalls, 1, memory_order_relaxed);
    atomic_store_explicit(&gActivePath, pathID, memory_order_relaxed);

    BOOL kOn = atomic_load_explicit(&gKaraokeOn, memory_order_relaxed);
    BOOL bOn = atomic_load_explicit(&gBoostOn, memory_order_relaxed);
    if (!kOn && !bOn) return;

    float kStr = kOn ? atomic_load_explicit(&gKaraokeStrength, memory_order_relaxed) : 0.0f;
    float gain = bOn ? atomic_load_explicit(&gBoostGain, memory_order_relaxed) : 1.0f;
    const float lpAlpha = 0.022f; // ~160 Hz 1-pole lowpass to preserve bass during vocal removal
    float lp = lpPtr ? *lpPtr : 0.0f;

    // 1. Non-interleaved stereo Float32 (standard iOS AURemoteIO / AVAudioEngine)
    if (ioData->mNumberBuffers == 2 &&
        ioData->mBuffers[0].mNumberChannels == 1 &&
        ioData->mBuffers[1].mNumberChannels == 1 &&
        ioData->mBuffers[0].mDataByteSize >= inNumberFrames * sizeof(float) &&
        ioData->mBuffers[1].mDataByteSize >= inNumberFrames * sizeof(float)) {
        float *L = (float *)ioData->mBuffers[0].mData;
        float *R = (float *)ioData->mBuffers[1].mData;
        if (L && R) {
            for (UInt32 i = 0; i < inNumberFrames; i++) {
                float l = L[i], r = R[i];
                if (kOn) {
                    float mid = 0.5f * (l + r);
                    lp += lpAlpha * (mid - lp);
                    float vocal = mid - lp;
                    l -= kStr * vocal;
                    r -= kStr * vocal;
                }
                if (bOn) {
                    l = IVLSoftClip(l * gain);
                    r = IVLSoftClip(r * gain);
                }
                L[i] = l;
                R[i] = r;
            }
            if (lpPtr) *lpPtr = lp;
            return;
        }
    }

    // 2. Interleaved stereo Float32
    if (ioData->mNumberBuffers == 1 &&
        ioData->mBuffers[0].mNumberChannels == 2 &&
        ioData->mBuffers[0].mDataByteSize >= inNumberFrames * 2 * sizeof(float)) {
        float *buf = (float *)ioData->mBuffers[0].mData;
        if (buf) {
            for (UInt32 i = 0; i < inNumberFrames; i++) {
                float l = buf[i * 2], r = buf[i * 2 + 1];
                if (kOn) {
                    float mid = 0.5f * (l + r);
                    lp += lpAlpha * (mid - lp);
                    float vocal = mid - lp;
                    l -= kStr * vocal;
                    r -= kStr * vocal;
                }
                if (bOn) {
                    l = IVLSoftClip(l * gain);
                    r = IVLSoftClip(r * gain);
                }
                buf[i * 2] = l;
                buf[i * 2 + 1] = r;
            }
            if (lpPtr) *lpPtr = lp;
            return;
        }
    }

    // 3. Interleaved stereo Int16
    if (ioData->mNumberBuffers == 1 &&
        ioData->mBuffers[0].mNumberChannels == 2 &&
        ioData->mBuffers[0].mDataByteSize >= inNumberFrames * 2 * sizeof(int16_t)) {
        int16_t *buf = (int16_t *)ioData->mBuffers[0].mData;
        if (buf) {
            for (UInt32 i = 0; i < inNumberFrames; i++) {
                float l = buf[i * 2] / 32768.0f;
                float r = buf[i * 2 + 1] / 32768.0f;
                if (kOn) {
                    float mid = 0.5f * (l + r);
                    lp += lpAlpha * (mid - lp);
                    float vocal = mid - lp;
                    l -= kStr * vocal;
                    r -= kStr * vocal;
                }
                if (bOn) {
                    l = IVLSoftClip(l * gain);
                    r = IVLSoftClip(r * gain);
                }
                l = fmaxf(-1.0f, fminf(1.0f, l));
                r = fmaxf(-1.0f, fminf(1.0f, r));
                buf[i * 2] = (int16_t)(l * 32767.0f);
                buf[i * 2 + 1] = (int16_t)(r * 32767.0f);
            }
            if (lpPtr) *lpPtr = lp;
        }
    }
}

#pragma mark - Hook 1: AudioUnitSetProperty (RenderCallback)

static OSStatus IVLDSPRenderCallback(void *inRefCon,
                                     AudioUnitRenderActionFlags *ioActionFlags,
                                     const AudioTimeStamp *inTimeStamp,
                                     UInt32 inBusNumber,
                                     UInt32 inNumberFrames,
                                     AudioBufferList *ioData) {
    IVLUnitEntry *entry = (IVLUnitEntry *)inRefCon;
    if (!entry || !entry->origProc) return noErr;
    OSStatus st = entry->origProc(entry->origRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    if (st == noErr) IVLProcessAudioBufferList(ioData, inNumberFrames, &entry->lpState, 1);
    return st;
}

typedef OSStatus (*IVLAudioUnitSetPropertyFn)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);
static IVLAudioUnitSetPropertyFn gOrigAudioUnitSetProperty = NULL;

static OSStatus IVLHookAudioUnitSetProperty(AudioUnit inUnit,
                                            AudioUnitPropertyID inID,
                                            AudioUnitScope inScope,
                                            AudioUnitElement inElement,
                                            const void *inData,
                                            UInt32 inDataSize) {
    IVLAudioUnitSetPropertyFn orig = gOrigAudioUnitSetProperty ?: AudioUnitSetProperty;
    if (inID == kAudioUnitProperty_SetRenderCallback && inData && inDataSize >= sizeof(AURenderCallbackStruct)) {
        const AURenderCallbackStruct *cb = (const AURenderCallbackStruct *)inData;
        if (cb->inputProc && cb->inputProc != IVLDSPRenderCallback) {
            pthread_mutex_lock(&gUnitsLock);
            IVLUnitEntry *slot = NULL;
            for (int i = 0; i < kIVLMaxUnits; i++) {
                if (gUnits[i].unit == inUnit) { slot = &gUnits[i]; break; }
            }
            if (!slot) {
                for (int i = 0; i < kIVLMaxUnits; i++) {
                    if (gUnits[i].unit == NULL) { slot = &gUnits[i]; break; }
                }
            }
            if (!slot) slot = &gUnits[0];
            slot->unit = inUnit;
            slot->origProc = cb->inputProc;
            slot->origRefCon = cb->inputProcRefCon;
            slot->lpState = 0.0f;
            pthread_mutex_unlock(&gUnitsLock);

            AURenderCallbackStruct wrapped;
            wrapped.inputProc = IVLDSPRenderCallback;
            wrapped.inputProcRefCon = slot;
            return orig(inUnit, inID, inScope, inElement, &wrapped, sizeof(wrapped));
        }
    }
    return orig(inUnit, inID, inScope, inElement, inData, inDataSize);
}

#pragma mark - Hook 2: AudioUnitRender (direct pull)

typedef OSStatus (*IVLAudioUnitRenderFn)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);
static IVLAudioUnitRenderFn gOrigAudioUnitRender = NULL;

static OSStatus IVLHookAudioUnitRender(AudioUnit inUnit,
                                       AudioUnitRenderActionFlags *ioActionFlags,
                                       const AudioTimeStamp *inTimeStamp,
                                       UInt32 inOutputBusNumber,
                                       UInt32 inNumberFrames,
                                       AudioBufferList *ioData) {
    IVLAudioUnitRenderFn orig = gOrigAudioUnitRender ?: AudioUnitRender;
    OSStatus st = orig(inUnit, ioActionFlags, inTimeStamp, inOutputBusNumber, inNumberFrames, ioData);
    // Avoid double-processing if RenderCallback already processed this unit
    if (st == noErr && atomic_load_explicit(&gActivePath, memory_order_relaxed) != 1) {
        IVLProcessAudioBufferList(ioData, inNumberFrames, &gGlobalLPState, 2);
    }
    return st;
}

#pragma mark - Hook 3: AudioQueueEnqueueBuffer (AudioQueue PCM path)

typedef OSStatus (*IVLAudioQueueEnqueueFn)(AudioQueueRef, AudioQueueBufferRef, UInt32, const AudioStreamPacketDescription *);
static IVLAudioQueueEnqueueFn gOrigAudioQueueEnqueue = NULL;

static OSStatus IVLHookAudioQueueEnqueueBuffer(AudioQueueRef inAQ,
                                               AudioQueueBufferRef inBuffer,
                                               UInt32 inNumPacketDescs,
                                               const AudioStreamPacketDescription *inPacketDescs) {
    IVLAudioQueueEnqueueFn orig = gOrigAudioQueueEnqueue ?: AudioQueueEnqueueBuffer;
    // Only touch linear PCM buffers (inNumPacketDescs == 0)
    if (inBuffer && inBuffer->mAudioData && inBuffer->mAudioDataByteSize >= 8 && inNumPacketDescs == 0) {
        AudioStreamBasicDescription asbd;
        UInt32 sz = sizeof(asbd);
        if (AudioQueueGetProperty(inAQ, kAudioQueueProperty_StreamDescription, &asbd, &sz) == noErr &&
            asbd.mFormatID == kAudioFormatLinearPCM && asbd.mChannelsPerFrame == 2) {
            AudioBufferList abl;
            abl.mNumberBuffers = 1;
            abl.mBuffers[0].mNumberChannels = 2;
            abl.mBuffers[0].mData = inBuffer->mAudioData;
            abl.mBuffers[0].mDataByteSize = inBuffer->mAudioDataByteSize;
            UInt32 frames = asbd.mBytesPerFrame > 0 ? (inBuffer->mAudioDataByteSize / asbd.mBytesPerFrame) : 0;
            if (frames > 0) IVLProcessAudioBufferList(&abl, frames, &gGlobalLPState, 3);
        }
    }
    return orig(inAQ, inBuffer, inNumPacketDescs, inPacketDescs);
}

#pragma mark - Mach-O symbol rebinding (__DATA & __DATA_CONST with vm_protect)

typedef struct {
    const char *name;
    void *replacement;
    void **origOut;
} IVLRebindTarget;

static void IVLRebindSection(const struct section_64 *sec,
                             intptr_t slide,
                             const struct nlist_64 *symtab,
                             const char *strtab,
                             const uint32_t *indirectSymtab,
                             BOOL isConstSegment) {
    static IVLRebindTarget targets[] = {
        { "AudioUnitSetProperty",    (void *)IVLHookAudioUnitSetProperty,    (void **)&gOrigAudioUnitSetProperty },
        { "AudioUnitRender",         (void *)IVLHookAudioUnitRender,         (void **)&gOrigAudioUnitRender },
        { "AudioQueueEnqueueBuffer", (void *)IVLHookAudioQueueEnqueueBuffer, (void **)&gOrigAudioQueueEnqueue },
    };
    const size_t nTargets = sizeof(targets) / sizeof(targets[0]);

    uint32_t *indirectIndices = (uint32_t *)(indirectSymtab + sec->reserved1);
    void **bindings = (void **)((uintptr_t)slide + sec->addr);
    size_t count = sec->size / sizeof(void *);

    BOOL madeWritable = NO;
    vm_address_t pageStart = (vm_address_t)((uintptr_t)bindings & ~(vm_page_size - 1));
    vm_size_t pageLen = (vm_size_t)((((uintptr_t)bindings + sec->size + vm_page_size - 1) & ~(vm_page_size - 1)) - pageStart);

    for (size_t i = 0; i < count; i++) {
        uint32_t symIdx = indirectIndices[i];
        if (symIdx == INDIRECT_SYMBOL_ABS || symIdx == INDIRECT_SYMBOL_LOCAL || symIdx == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) continue;
        uint32_t strOff = symtab[symIdx].n_un.n_strx;
        const char *symName = strtab + strOff;
        if (symName[0] != '_') continue;

        for (size_t t = 0; t < nTargets; t++) {
            if (strcmp(symName + 1, targets[t].name) == 0) {
                if (isConstSegment && !madeWritable) {
                    kern_return_t kr = vm_protect(mach_task_self(), pageStart, pageLen, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                    if (kr != KERN_SUCCESS) return;
                    madeWritable = YES;
                }
                if (targets[t].origOut && !*(targets[t].origOut) && bindings[i] != targets[t].replacement) {
                    *(targets[t].origOut) = bindings[i];
                }
                bindings[i] = targets[t].replacement;
                atomic_fetch_add_explicit(&gRebindHits, 1, memory_order_relaxed);
                break;
            }
        }
    }
    if (madeWritable) {
        vm_protect(mach_task_self(), pageStart, pageLen, FALSE, VM_PROT_READ);
    }
}

static void IVLRebindImage(const struct mach_header *header, intptr_t slide) {
    if (!header || header->magic != MH_MAGIC_64) return;
    const struct mach_header_64 *mh = (const struct mach_header_64 *)header;
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtabCmd = NULL;
    const struct dysymtab_command *dysymtabCmd = NULL;

    uintptr_t cur = (uintptr_t)mh + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cur;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strcmp(seg->segname, SEG_LINKEDIT) == 0) linkedit = seg;
        } else if (lc->cmd == LC_SYMTAB) {
            symtabCmd = (const struct symtab_command *)lc;
        } else if (lc->cmd == LC_DYSYMTAB) {
            dysymtabCmd = (const struct dysymtab_command *)lc;
        }
        cur += lc->cmdsize;
    }
    if (!linkedit || !symtabCmd || !dysymtabCmd || dysymtabCmd->nindirectsyms == 0) return;

    uintptr_t linkeditBase = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *symtab = (const struct nlist_64 *)(linkeditBase + symtabCmd->symoff);
    const char *strtab = (const char *)(linkeditBase + symtabCmd->stroff);
    const uint32_t *indirectSymtab = (const uint32_t *)(linkeditBase + dysymtabCmd->indirectsymoff);

    cur = (uintptr_t)mh + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cur;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            BOOL isData = (strcmp(seg->segname, SEG_DATA) == 0);
            BOOL isConst = (strcmp(seg->segname, "__DATA_CONST") == 0);
            if (isData || isConst) {
                const struct section_64 *secs = (const struct section_64 *)(cur + sizeof(struct segment_command_64));
                for (uint32_t j = 0; j < seg->nsects; j++) {
                    uint32_t type = secs[j].flags & SECTION_TYPE;
                    if (type == S_LAZY_SYMBOL_POINTERS || type == S_NON_LAZY_SYMBOL_POINTERS) {
                        IVLRebindSection(&secs[j], slide, symtab, strtab, indirectSymtab, isConst);
                    }
                }
            }
        }
        cur += lc->cmdsize;
    }
}

#pragma mark - Half-sheet Quick Audio DSP Controller (accessible right from the lyrics screen)

@interface IVLAudioSheetViewController : UITableViewController
@end

@implementation IVLAudioSheetViewController {
    NSTimer *_statusTimer;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = IVLLoc(@"sec_audio");
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    _statusTimer = [NSTimer scheduledTimerWithTimeInterval:0.8 target:self selector:@selector(refreshStatus) userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_statusTimer invalidate];
    _statusTimer = nil;
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)refreshStatus {
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:2] withRowAnimation:UITableViewRowAnimationNone];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 2 ? 1 : 2; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return IVLLoc(@"footer_karaoke_mode");
    if (section == 1) return IVLLoc(@"footer_volume_boost");
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 2) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        c.textLabel.text = IVLLoc(@"status");
        c.detailTextLabel.text = [IVLAudioDSP statusText];
        return c;
    }
    if (indexPath.row == 0) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        NSString *key = (indexPath.section == 0) ? IVLKeyKaraokeMode : IVLKeyVolumeBoost;
        c.textLabel.text = (indexPath.section == 0) ? IVLLoc(@"karaoke_mode") : IVLLoc(@"volume_boost");
        UISwitch *sw = [UISwitch new];
        sw.on = [IVLSettings boolForKey:key];
        [sw addAction:[UIAction actionWithHandler:^(UIAction *a) {
            [IVLSettings setBool:((UISwitch *)a.sender).on forKey:key];
        }] forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
        return c;
    }
    // Live slider row
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    BOOL isKaraoke = (indexPath.section == 0);
    NSString *key = isKaraoke ? IVLKeyKaraokeStrength : IVLKeyVolumeBoostLevel;
    double minV = isKaraoke ? 0.0 : 100.0;
    double maxV = isKaraoke ? 100.0 : 250.0;
    double cur = MAX(minV, MIN(maxV, [IVLSettings doubleForKey:key]));

    UILabel *title = [UILabel new];
    title.text = isKaraoke ? IVLLoc(@"karaoke_strength") : IVLLoc(@"volume_boost_level");
    UILabel *val = [UILabel new];
    val.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
    val.textColor = UIColor.secondaryLabelColor;
    val.text = [NSString stringWithFormat:@"%.0f%%", cur];

    UISlider *sl = [UISlider new];
    sl.minimumValue = minV; sl.maximumValue = maxV; sl.value = cur;
    [sl addAction:[UIAction actionWithHandler:^(UIAction *a) {
        double v = round(((UISlider *)a.sender).value / 5.0) * 5.0;
        val.text = [NSString stringWithFormat:@"%.0f%%", v];
        [IVLSettings setObject:@(v) forKey:key];
    }] forControlEvents:UIControlEventValueChanged];

    UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[title, val]];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[top, sl]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [c.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:c.contentView.layoutMarginsGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:c.contentView.layoutMarginsGuide.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:c.contentView.topAnchor constant:10],
        [stack.bottomAnchor constraintEqualToAnchor:c.contentView.bottomAnchor constant:-10],
    ]];
    return c;
}

@end

#pragma mark - Manager

@implementation IVLAudioDSP {
    BOOL _started;
}

+ (instancetype)shared {
    static IVLAudioDSP *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [self new]; });
    return s;
}

+ (NSString *)statusText {
    uint64_t calls = atomic_load_explicit(&gProcessedCalls, memory_order_relaxed);
    int path = atomic_load_explicit(&gActivePath, memory_order_relaxed);
    int hits = atomic_load_explicit(&gRebindHits, memory_order_relaxed);
    if (calls > 0) {
        NSString *pName = @"DSP";
        switch (path) {
            case 1: pName = @"AudioUnit CB"; break;
            case 2: pName = @"AudioUnit"; break;
            case 3: pName = @"AudioQueue"; break;
            case 4: pName = @"AVAudioPlayerNode"; break;
            case 5: pName = @"SampleBuf PCM"; break;
            case 6: pName = @"AVPlayerTap"; break;
            case 7: pName = @"SampleBuf (passthrough)"; break;
            case 8: pName = @"SampleBuf DSP"; break;
            default: break;
        }
        return [NSString stringWithFormat:@"Active (%@)", pName];
    }
    return [NSString stringWithFormat:@"Standby (hooks: %d)", hits];
}

+ (void)processPCMBuffer:(AVAudioPCMBuffer *)buffer {
    if (!buffer || buffer.frameLength == 0) return;
    AudioBufferList *abl = buffer.mutableAudioBufferList;
    if (abl) {
        IVLProcessAudioBufferList(abl, buffer.frameLength, &gGlobalLPState, 4);
    }
}

#pragma mark - Real-time AudioConverter decoder for encoded CMSampleBuffer (AAC/Opus -> Float32 PCM -> DSP)

typedef struct {
    AudioConverterRef converter;
    AudioStreamBasicDescription inASBD;
    AudioStreamBasicDescription outASBD;
    CMFormatDescriptionRef outFmt;
    void *cookie;
    size_t cookieSize;
} IVLSampleDecoder;

static IVLSampleDecoder gDecoder = {0};
static pthread_mutex_t gDecoderLock = PTHREAD_MUTEX_INITIALIZER;

typedef struct {
    const uint8_t *bytes;
    size_t byteLen;
    AudioStreamPacketDescription *pktDescs;
    UInt32 numPackets;
    UInt32 consumedPackets;
    AudioStreamPacketDescription fallbackDesc;
} IVLConverterFeed;

static OSStatus IVLConverterInputProc(AudioConverterRef inAudioConverter,
                                      UInt32 *ioNumberDataPackets,
                                      AudioBufferList *ioData,
                                      AudioStreamPacketDescription **outDataPacketDescription,
                                      void *inUserData) {
    IVLConverterFeed *feed = (IVLConverterFeed *)inUserData;
    if (!feed || feed->consumedPackets >= feed->numPackets) {
        *ioNumberDataPackets = 0;
        return noErr;
    }
    UInt32 remaining = feed->numPackets - feed->consumedPackets;
    UInt32 give = (*ioNumberDataPackets < remaining) ? *ioNumberDataPackets : remaining;

    if (feed->pktDescs) {
        AudioStreamPacketDescription *startDesc = &feed->pktDescs[feed->consumedPackets];
        ioData->mNumberBuffers = 1;
        ioData->mBuffers[0].mData = (void *)feed->bytes;
        ioData->mBuffers[0].mDataByteSize = (UInt32)feed->byteLen;
        if (outDataPacketDescription) *outDataPacketDescription = startDesc;
        feed->consumedPackets += give;
        *ioNumberDataPackets = give;
    } else {
        ioData->mNumberBuffers = 1;
        ioData->mBuffers[0].mData = (void *)feed->bytes;
        ioData->mBuffers[0].mDataByteSize = (UInt32)feed->byteLen;
        if (outDataPacketDescription) {
            feed->fallbackDesc.mStartOffset = 0;
            feed->fallbackDesc.mVariableFramesInPacket = 0;
            feed->fallbackDesc.mDataByteSize = (UInt32)feed->byteLen;
            *outDataPacketDescription = &feed->fallbackDesc;
        }
        feed->consumedPackets = feed->numPackets;
        *ioNumberDataPackets = remaining;
    }
    return noErr;
}

static BOOL IVLEnsureDecoderLocked(const AudioStreamBasicDescription *inASBD, CMFormatDescriptionRef fmtDesc) {
    size_t cSize = 0;
    const void *cPtr = CMAudioFormatDescriptionGetMagicCookie(fmtDesc, &cSize);

    BOOL sameASBD = (gDecoder.converter != NULL &&
                     memcmp(&gDecoder.inASBD, inASBD, sizeof(AudioStreamBasicDescription)) == 0 &&
                     gDecoder.cookieSize == cSize &&
                     (cSize == 0 || (gDecoder.cookie && cPtr && memcmp(gDecoder.cookie, cPtr, cSize) == 0)));
    if (sameASBD) return YES;

    if (gDecoder.converter) { AudioConverterDispose(gDecoder.converter); gDecoder.converter = NULL; }
    if (gDecoder.outFmt) { CFRelease(gDecoder.outFmt); gDecoder.outFmt = NULL; }
    if (gDecoder.cookie) { free(gDecoder.cookie); gDecoder.cookie = NULL; gDecoder.cookieSize = 0; }

    AudioStreamBasicDescription outASBD;
    memset(&outASBD, 0, sizeof(outASBD));
    outASBD.mSampleRate = inASBD->mSampleRate > 0 ? inASBD->mSampleRate : 44100.0;
    outASBD.mFormatID = kAudioFormatLinearPCM;
    outASBD.mFormatFlags = kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked;
    outASBD.mBitsPerChannel = 32;
    outASBD.mChannelsPerFrame = 2;
    outASBD.mBytesPerFrame = 2 * sizeof(float);
    outASBD.mFramesPerPacket = 1;
    outASBD.mBytesPerPacket = outASBD.mBytesPerFrame;

    AudioConverterRef conv = NULL;
    if (AudioConverterNew(inASBD, &outASBD, &conv) != noErr || !conv) return NO;
    if (cPtr && cSize > 0) {
        AudioConverterSetProperty(conv, kAudioConverterDecompressionMagicCookie, (UInt32)cSize, cPtr);
        gDecoder.cookie = malloc(cSize);
        if (gDecoder.cookie) { memcpy(gDecoder.cookie, cPtr, cSize); gDecoder.cookieSize = cSize; }
    }
    CMFormatDescriptionRef outFmt = NULL;
    if (CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &outASBD, 0, NULL, 0, NULL, NULL, &outFmt) != noErr || !outFmt) {
        AudioConverterDispose(conv);
        return NO;
    }

    gDecoder.converter = conv;
    gDecoder.inASBD = *inASBD;
    gDecoder.outASBD = outASBD;
    gDecoder.outFmt = outFmt;
    return YES;
}

+ (void)resetDecoder {
    pthread_mutex_lock(&gDecoderLock);
    if (gDecoder.converter) AudioConverterReset(gDecoder.converter);
    gGlobalLPState = 0.0f;
    pthread_mutex_unlock(&gDecoderLock);
}

+ (CMSampleBufferRef)createProcessedSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!sampleBuffer) return NULL;
    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
    const AudioStreamBasicDescription *asbd = fmt ? CMAudioFormatDescriptionGetStreamBasicDescription(fmt) : NULL;
    if (!asbd) return NULL;

    // Linear PCM path (in-place)
    if (asbd->mFormatID == kAudioFormatLinearPCM) {
        CMBlockBufferRef blockBuf = NULL;
        AudioBufferList abl;
        OSStatus st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, NULL, &abl, sizeof(abl), NULL, NULL,
            kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &blockBuf);
        if (st == noErr) {
            UInt32 frames = (UInt32)CMSampleBufferGetNumSamples(sampleBuffer);
            if (frames > 0) IVLProcessAudioBufferList(&abl, frames, &gGlobalLPState, 5);
        }
        if (blockBuf) CFRelease(blockBuf);
        return NULL;
    }

    // Encoded audio path (AAC / HE-AAC / Opus): zero-cost passthrough when both Karaoke & Boost are OFF
    BOOL kOn = atomic_load_explicit(&gKaraokeOn, memory_order_relaxed);
    BOOL bOn = atomic_load_explicit(&gBoostOn, memory_order_relaxed);
    if (!kOn && !bOn) {
        atomic_fetch_add_explicit(&gProcessedCalls, 1, memory_order_relaxed);
        atomic_store_explicit(&gActivePath, 7, memory_order_relaxed);
        return NULL;
    }

    CMBlockBufferRef inBB = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!inBB) return NULL;
    size_t totalLen = CMBlockBufferGetDataLength(inBB);
    if (totalLen == 0) return NULL;

    uint8_t *rawBytes = (uint8_t *)malloc(totalLen);
    if (!rawBytes) return NULL;
    if (CMBlockBufferCopyDataBytes(inBB, 0, totalLen, rawBytes) != kCMBlockBufferNoErr) {
        free(rawBytes);
        return NULL;
    }

    CMItemCount numSamples = CMSampleBufferGetNumSamples(sampleBuffer);
    size_t pdSize = 0;
    AudioStreamPacketDescription *pktDescs = NULL;
    UInt32 numPackets = (UInt32)MAX(1, numSamples);
    if (CMSampleBufferGetAudioStreamPacketDescriptions(sampleBuffer, 0, NULL, &pdSize) == noErr && pdSize > 0) {
        pktDescs = (AudioStreamPacketDescription *)malloc(pdSize);
        if (pktDescs) {
            if (CMSampleBufferGetAudioStreamPacketDescriptions(sampleBuffer, pdSize, pktDescs, NULL) == noErr) {
                numPackets = (UInt32)(pdSize / sizeof(AudioStreamPacketDescription));
            } else {
                free(pktDescs);
                pktDescs = NULL;
            }
        }
    }

    UInt32 framesPerPkt = asbd->mFramesPerPacket > 0 ? asbd->mFramesPerPacket : 2048;
    UInt32 maxOutFrames = MAX((UInt32)numSamples, numPackets * framesPerPkt) + 2048;
    size_t outBytes = (size_t)maxOutFrames * 2 * sizeof(float);
    float *pcmOut = (float *)malloc(outBytes);
    if (!pcmOut) {
        free(rawBytes);
        if (pktDescs) free(pktDescs);
        return NULL;
    }

    UInt32 totalDecoded = 0;
    CMFormatDescriptionRef outFmtRetained = NULL;

    pthread_mutex_lock(&gDecoderLock);
    if (IVLEnsureDecoderLocked(asbd, fmt)) {
        IVLConverterFeed feed = { rawBytes, totalLen, pktDescs, numPackets, 0 };
        while (feed.consumedPackets < feed.numPackets && totalDecoded < maxOutFrames) {
            UInt32 want = maxOutFrames - totalDecoded;
            AudioBufferList outABL;
            outABL.mNumberBuffers = 1;
            outABL.mBuffers[0].mNumberChannels = 2;
            outABL.mBuffers[0].mData = pcmOut + (totalDecoded * 2);
            outABL.mBuffers[0].mDataByteSize = want * 2 * sizeof(float);
            OSStatus st = AudioConverterFillComplexBuffer(gDecoder.converter, IVLConverterInputProc, &feed, &want, &outABL, NULL);
            if (want > 0) totalDecoded += want;
            if (st != noErr || want == 0) break;
        }
        if (totalDecoded > 0 && gDecoder.outFmt) {
            AudioBufferList dspABL;
            dspABL.mNumberBuffers = 1;
            dspABL.mBuffers[0].mNumberChannels = 2;
            dspABL.mBuffers[0].mData = pcmOut;
            dspABL.mBuffers[0].mDataByteSize = totalDecoded * 2 * sizeof(float);
            IVLProcessAudioBufferList(&dspABL, totalDecoded, &gGlobalLPState, 8);
            outFmtRetained = (CMFormatDescriptionRef)CFRetain(gDecoder.outFmt);
        }
    }
    pthread_mutex_unlock(&gDecoderLock);

    free(rawBytes);
    if (pktDescs) free(pktDescs);

    if (totalDecoded == 0 || !outFmtRetained) {
        free(pcmOut);
        if (outFmtRetained) CFRelease(outFmtRetained);
        return NULL;
    }

    size_t finalBytes = (size_t)totalDecoded * 2 * sizeof(float);
    CMBlockBufferRef outBB = NULL;
    OSStatus bbSt = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, pcmOut, finalBytes, kCFAllocatorMalloc, NULL, 0, finalBytes, 0, &outBB);
    if (bbSt != kCMBlockBufferNoErr || !outBB) {
        free(pcmOut);
        CFRelease(outFmtRetained);
        return NULL;
    }

    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);

    CMSampleBufferRef outSB = NULL;
    OSStatus sbSt = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        kCFAllocatorDefault, outBB, outFmtRetained, totalDecoded, pts, NULL, &outSB);
    CFRelease(outBB);
    CFRelease(outFmtRetained);
    return (sbSt == noErr) ? outSB : NULL;
}

static void IVLTapProcess(MTAudioProcessingTapRef tap,
                          CMItemCount numberFrames,
                          MTAudioProcessingTapFlags flags,
                          AudioBufferList *bufferListInOut,
                          CMItemCount *numberFramesOut,
                          MTAudioProcessingTapFlags *flagsOut) {
    OSStatus st = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, NULL, numberFramesOut);
    if (st == noErr && numberFramesOut && *numberFramesOut > 0) {
        IVLProcessAudioBufferList(bufferListInOut, (UInt32)(*numberFramesOut), &gGlobalLPState, 6);
    }
}

+ (void)attachTapToPlayerItem:(AVPlayerItem *)item {
    if (!item || ![item isKindOfClass:[AVPlayerItem class]]) return;
    static const void *kIVLTapAttachedKey = &kIVLTapAttachedKey;
    if (objc_getAssociatedObject(item, kIVLTapAttachedKey)) return;
    AVAsset *asset = item.asset;
    if (!asset) return;
    NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    AVAssetTrack *track = tracks.firstObject;
    if (!track) return;

    MTAudioProcessingTapCallbacks callbacks;
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.version = kMTAudioProcessingTapCallbacksVersion_0;
    callbacks.process = IVLTapProcess;
    MTAudioProcessingTapRef tap = NULL;
    if (MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) != noErr || !tap) return;

    AVMutableAudioMixInputParameters *params = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:track];
    params.audioTapProcessor = tap;
    CFRelease(tap);

    AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
    mix.inputParameters = @[params];
    item.audioMix = mix;
    objc_setAssociatedObject(item, kIVLTapAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

+ (void)presentQuickSheetFrom:(UIViewController *)vc {
    if (!vc) return;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[IVLAudioSheetViewController new]];
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sh = nav.sheetPresentationController;
        sh.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
        sh.prefersGrabberVisible = YES;
    }
    [vc presentViewController:nav animated:YES completion:nil];
}

- (void)start {
    if (_started) return;
    _started = YES;
    gOrigAudioUnitSetProperty = (IVLAudioUnitSetPropertyFn)dlsym(RTLD_DEFAULT, "AudioUnitSetProperty");
    gOrigAudioUnitRender = (IVLAudioUnitRenderFn)dlsym(RTLD_DEFAULT, "AudioUnitRender");
    gOrigAudioQueueEnqueue = (IVLAudioQueueEnqueueFn)dlsym(RTLD_DEFAULT, "AudioQueueEnqueueBuffer");
    [self syncSettings];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(syncSettings) name:IVLSettingsDidChangeNotification object:nil];
    _dyld_register_func_for_add_image(IVLRebindImage);
}

- (void)syncSettings {
    BOOL kOn = [IVLSettings boolForKey:IVLKeyKaraokeMode];
    double kStr = [IVLSettings doubleForKey:IVLKeyKaraokeStrength];
    if (kStr < 0 || kStr > 100) kStr = 85.0;

    BOOL bOn = [IVLSettings boolForKey:IVLKeyVolumeBoost];
    double bPct = [IVLSettings doubleForKey:IVLKeyVolumeBoostLevel];
    if (bPct < 100 || bPct > 250) bPct = 150.0;

    atomic_store_explicit(&gKaraokeOn, kOn, memory_order_relaxed);
    atomic_store_explicit(&gKaraokeStrength, (float)(kStr / 100.0), memory_order_relaxed);
    atomic_store_explicit(&gBoostOn, bOn, memory_order_relaxed);
    atomic_store_explicit(&gBoostGain, (float)(bPct / 100.0), memory_order_relaxed);
}

@end
