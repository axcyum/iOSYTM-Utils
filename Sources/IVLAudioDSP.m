#import "IVLAudioDSP.h"
#import "IVLSettings.h"
#import <AudioToolbox/AudioToolbox.h>
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

#pragma mark - Render callback registry (fixed-size lock-free table for audio thread safety)

typedef struct {
    AudioUnit unit;
    AURenderCallback origProc;
    void *origRefCon;
    float lpState; // 1-pole lowpass state (~160 Hz) to preserve bass during vocal removal
} IVLUnitEntry;

#define kIVLMaxUnits 32
static IVLUnitEntry gUnits[kIVLMaxUnits];
static pthread_mutex_t gUnitsLock = PTHREAD_MUTEX_INITIALIZER;

static inline float IVLSoftClip(float x) {
    if (x > 0.85f) return 0.85f + 0.15f * tanhf((x - 0.85f) / 0.15f);
    if (x < -0.85f) return -0.85f + 0.15f * tanhf((x + 0.85f) / 0.15f);
    return x;
}

static OSStatus IVLDSPRenderCallback(void *inRefCon,
                                     AudioUnitRenderActionFlags *ioActionFlags,
                                     const AudioTimeStamp *inTimeStamp,
                                     UInt32 inBusNumber,
                                     UInt32 inNumberFrames,
                                     AudioBufferList *ioData) {
    IVLUnitEntry *entry = (IVLUnitEntry *)inRefCon;
    if (!entry || !entry->origProc) return noErr;

    OSStatus st = entry->origProc(entry->origRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    if (st != noErr || !ioData || ioData->mNumberBuffers == 0 || inNumberFrames == 0) return st;

    BOOL kOn = atomic_load_explicit(&gKaraokeOn, memory_order_relaxed);
    BOOL bOn = atomic_load_explicit(&gBoostOn, memory_order_relaxed);
    if (!kOn && !bOn) return st;

    float kStr = kOn ? atomic_load_explicit(&gKaraokeStrength, memory_order_relaxed) : 0.0f;
    float gain = bOn ? atomic_load_explicit(&gBoostGain, memory_order_relaxed) : 1.0f;
    // 1-pole lowpass alpha for ~160 Hz at 44.1/48 kHz
    const float lpAlpha = 0.022f;
    float lp = entry->lpState;

    // Case 1: Non-interleaved stereo Float32 (standard iOS AURemoteIO / AVAudioEngine format)
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
                    float vocal = mid - lp; // high-pass center (vocals) while keeping bass
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
            entry->lpState = lp;
            return st;
        }
    }

    // Case 2: Interleaved stereo Float32
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
            entry->lpState = lp;
            return st;
        }
    }

    // Case 3: Interleaved stereo Int16 (SInt16)
    if (ioData->mNumberBuffers == 1 &&
        ioData->mBuffers[0].mNumberChannels == 2 &&
        ioData->mBuffers[0].mDataByteSize == inNumberFrames * 2 * sizeof(int16_t)) {
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
            entry->lpState = lp;
        }
    }
    return st;
}

#pragma mark - AudioUnitSetProperty hook via Mach-O symbol rebinding

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

// Minimal 64-bit Mach-O lazy/non-lazy symbol pointer rebinding (fishhook algorithm)
static void IVLRebindSection(const struct section_64 *sec,
                             intptr_t slide,
                             const struct nlist_64 *symtab,
                             const char *strtab,
                             const uint32_t *indirectSymtab,
                             const char *targetSym,
                             void *replacement,
                             void **origOut) {
    uint32_t *indirectIndices = (uint32_t *)(indirectSymtab + sec->reserved1);
    void **bindings = (void **)((uintptr_t)slide + sec->addr);
    size_t count = sec->size / sizeof(void *);
    for (size_t i = 0; i < count; i++) {
        uint32_t symIdx = indirectIndices[i];
        if (symIdx == INDIRECT_SYMBOL_ABS || symIdx == INDIRECT_SYMBOL_LOCAL || symIdx == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) continue;
        uint32_t strOff = symtab[symIdx].n_un.n_strx;
        const char *symName = strtab + strOff;
        if (symName[0] == '_' && strcmp(symName + 1, targetSym) == 0) {
            if (origOut && !*origOut && bindings[i] != replacement) *origOut = bindings[i];
            bindings[i] = replacement;
        }
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
            if (strcmp(seg->segname, SEG_DATA) == 0 || strcmp(seg->segname, "__DATA_CONST") == 0) {
                const struct section_64 *secs = (const struct section_64 *)(cur + sizeof(struct segment_command_64));
                for (uint32_t j = 0; j < seg->nsects; j++) {
                    uint32_t type = secs[j].flags & SECTION_TYPE;
                    if (type == S_LAZY_SYMBOL_POINTERS || type == S_NON_LAZY_SYMBOL_POINTERS) {
                        // Only rebind writable __DATA lazy pointers to avoid faulting on read-only __DATA_CONST
                        if (strcmp(seg->segname, SEG_DATA) == 0) {
                            IVLRebindSection(&secs[j], slide, symtab, strtab, indirectSymtab,
                                             "AudioUnitSetProperty", (void *)IVLHookAudioUnitSetProperty,
                                             (void **)&gOrigAudioUnitSetProperty);
                        }
                    }
                }
            }
        }
        cur += lc->cmdsize;
    }
}

@implementation IVLAudioDSP {
    BOOL _started;
}

+ (instancetype)shared {
    static IVLAudioDSP *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [self new]; });
    return s;
}

- (void)start {
    if (_started) return;
    _started = YES;
    gOrigAudioUnitSetProperty = (IVLAudioUnitSetPropertyFn)dlsym(RTLD_DEFAULT, "AudioUnitSetProperty");
    [self syncSettings];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(syncSettings) name:IVLSettingsDidChangeNotification object:nil];
    _dyld_register_func_for_add_image(IVLRebindImage);
}

- (void)syncSettings {
    BOOL kOn = [IVLSettings boolForKey:IVLKeyKaraokeMode];
    double kStr = [IVLSettings doubleForKey:IVLKeyKaraokeStrength];
    if (kStr <= 0 || kStr > 100) kStr = 85.0;

    BOOL bOn = [IVLSettings boolForKey:IVLKeyVolumeBoost];
    double bPct = [IVLSettings doubleForKey:IVLKeyVolumeBoostLevel];
    if (bPct < 100 || bPct > 250) bPct = 150.0;

    atomic_store_explicit(&gKaraokeOn, kOn, memory_order_relaxed);
    atomic_store_explicit(&gKaraokeStrength, (float)(kStr / 100.0), memory_order_relaxed);
    atomic_store_explicit(&gBoostOn, bOn, memory_order_relaxed);
    atomic_store_explicit(&gBoostGain, (float)(bPct / 100.0), memory_order_relaxed);
}

@end
