#import "IVLAudioDSP.h"
#import "IVLSettings.h"
#import "IVLLocalization.h"
#import "IVLPlaybackManager.h"
#import "YTMHeaders.h"
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

#import "IVLExtras.h"

// Real-time lock-free DSP parameters (updated on main thread, read in audio render thread)
static _Atomic BOOL gKaraokeOn = NO;
static _Atomic float gKaraokeStrength = 0.85f;
static _Atomic BOOL gBoostOn = NO;
static _Atomic float gBoostGain = 1.84f;
static _Atomic BOOL gEQOn = NO;
static _Atomic uint64_t gProcessedCalls = 0;
static _Atomic uint64_t gDecodedFramesTotal = 0;
static _Atomic int gActivePath = 0;
static _Atomic int gRebindHits = 0;
static _Atomic uint32_t gLastFormatID = 0;
static _Atomic int gLastStage = 0;      // 0=ok, 1=inBB, 2=convNew, 3=fillErr, 4=sbarFail
static _Atomic int gLastError = 0;
static _Atomic int gSBARFailCount = 0;
static _Atomic int gSampleRateHz = 48000;

#define kIVLEQBandCount 6
static const double kIVLEQFreqs[kIVLEQBandCount] = { 60.0, 150.0, 400.0, 1000.0, 2400.0, 12000.0 };

typedef struct {
    float b0, b1, b2, a1, a2;
} IVLBiquadCoeffs;

typedef struct {
    IVLBiquadCoeffs bands[kIVLEQBandCount];
    float preamp;
    int sampleRate;
} IVLEQBank;

static IVLEQBank gEQBanks[2];
static _Atomic int gActiveEQBank = 0;
static double gCurrentEQGainsDB[kIVLEQBandCount] = { 0, 0, 0, 0, 0, 0 };

typedef struct {
    float lpLow;
    float lpHigh;
    float z1L[kIVLEQBandCount];
    float z2L[kIVLEQBandCount];
    float z1R[kIVLEQBandCount];
    float z2R[kIVLEQBandCount];
    float limEnv;
    float limGain;
    BOOL limInited;
} IVLFilterState;

static void IVLBuildEQBank(IVLEQBank *bank, const double gainsDB[kIVLEQBandCount], double sr) {
    if (sr < 8000.0) sr = 48000.0;
    bank->sampleRate = (int)sr;
    double maxPos = 0.0;
    for (int i = 0; i < kIVLEQBandCount; i++) {
        double g = gainsDB[i];
        if (g > maxPos) maxPos = g;
        if (fabs(g) < 0.05) {
            bank->bands[i] = (IVLBiquadCoeffs){ 1.0f, 0.0f, 0.0f, 0.0f, 0.0f };
            continue;
        }
        double freq = fmin(kIVLEQFreqs[i], sr * 0.45);
        double A = pow(10.0, g / 40.0);
        double w0 = 2.0 * M_PI * freq / sr;
        double cosw = cos(w0), sinw = sin(w0);
        double b0, b1, b2, a0, a1, a2;

        if (i == 0) {
            // Low-shelf (60 Hz)
            double alpha = sinw / (2.0 * 0.70710678);
            double sq = 2.0 * sqrt(A) * alpha;
            b0 = A * ((A + 1.0) - (A - 1.0) * cosw + sq);
            b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cosw);
            b2 = A * ((A + 1.0) - (A - 1.0) * cosw - sq);
            a0 = (A + 1.0) + (A - 1.0) * cosw + sq;
            a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cosw);
            a2 = (A + 1.0) + (A - 1.0) * cosw - sq;
        } else if (i == kIVLEQBandCount - 1) {
            // High-shelf (12 kHz)
            double alpha = sinw / (2.0 * 0.70710678);
            double sq = 2.0 * sqrt(A) * alpha;
            b0 = A * ((A + 1.0) + (A - 1.0) * cosw + sq);
            b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosw);
            b2 = A * ((A + 1.0) + (A - 1.0) * cosw - sq);
            a0 = (A + 1.0) - (A - 1.0) * cosw + sq;
            a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cosw);
            a2 = (A + 1.0) - (A - 1.0) * cosw - sq;
        } else {
            // Peaking EQ (Q = 1.1)
            double alpha = sinw / (2.0 * 1.1);
            b0 = 1.0 + alpha * A;
            b1 = -2.0 * cosw;
            b2 = 1.0 - alpha * A;
            a0 = 1.0 + alpha / A;
            a1 = -2.0 * cosw;
            a2 = 1.0 - alpha / A;
        }
        bank->bands[i].b0 = (float)(b0 / a0);
        bank->bands[i].b1 = (float)(b1 / a0);
        bank->bands[i].b2 = (float)(b2 / a0);
        bank->bands[i].a1 = (float)(a1 / a0);
        bank->bands[i].a2 = (float)(a2 / a0);
    }
    // Gentle headroom trim when boosting bands heavily so peaks stay clean before soft-clip
    bank->preamp = (maxPos > 2.5) ? powf(10.0f, (float)(-0.32 * (maxPos - 2.5) / 20.0)) : 1.0f;
}

static inline void IVLApplyEQSampleStereo(const IVLEQBank *bank, IVLFilterState *st, float *ioL, float *ioR) {
    float l = (*ioL) * bank->preamp;
    float r = (*ioR) * bank->preamp;
    for (int b = 0; b < kIVLEQBandCount; b++) {
        const IVLBiquadCoeffs c = bank->bands[b];
        float yl = c.b0 * l + st->z1L[b];
        st->z1L[b] = c.b1 * l - c.a1 * yl + st->z2L[b];
        st->z2L[b] = c.b2 * l - c.a2 * yl;
        l = yl;

        float yr = c.b0 * r + st->z1R[b];
        st->z1R[b] = c.b1 * r - c.a1 * yr + st->z2R[b];
        st->z2R[b] = c.b2 * r - c.a2 * yr;
        r = yr;
    }
    *ioL = l;
    *ioR = r;
}

typedef struct {
    AudioUnit unit;
    AURenderCallback origProc;
    void *origRefCon;
    IVLFilterState flt;
} IVLUnitEntry;

#define kIVLMaxUnits 32
static IVLUnitEntry gUnits[kIVLMaxUnits];
static pthread_mutex_t gUnitsLock = PTHREAD_MUTEX_INITIALIZER;
static IVLFilterState gGlobalFilter = {0};

#pragma mark - Renderer Volume Registry (AVSampleBufferAudioRenderer / AVPlayer / AVAudioPlayerNode / AVAudioPlayer)

static NSHashTable *gRenderers = nil;
static pthread_mutex_t gRenderersLock = PTHREAD_MUTEX_INITIALIZER;
static const void *kIVLBaseVolumeKey = &kIVLBaseVolumeKey;
static __thread BOOL tReapplyingVolume = NO;

// Transparent safety ceiling — only engages above 0.95 (-0.45 dBFS) if a sub-sample transient slips past the limiter.
static inline float IVLSafetyCeiling(float x) {
    if (x > 0.95f) return 0.95f + 0.035f * tanhf((x - 0.95f) / 0.035f);
    if (x < -0.95f) return -0.95f + 0.035f * tanhf((x + 0.95f) / 0.035f);
    return x;
}

// Stereo-linked dynamic soft-knee compressor + brickwall peak limiter.
// Keeps boosted audio loud and clean without static waveshaper harmonic distortion (clipping).
static inline void IVLApplyDynamicBoostStereo(IVLFilterState *st, float gain, float relCoeff, float *ioL, float *ioR) {
    float l = (*ioL) * gain;
    float r = (*ioR) * gain;
    float peak = fmaxf(fabsf(l), fabsf(r));

    const float knee = 0.72f;     // -2.85 dBFS: gentle compression begins
    const float ceiling = 0.91f;  // -0.82 dBFS: clean true-peak headroom for DAC / BT codecs

    if (peak > st->limEnv) {
        st->limEnv = peak; // instant attack catches transients cleanly
    } else {
        st->limEnv += relCoeff * (peak - st->limEnv);
    }

    float targetGain = 1.0f;
    if (st->limEnv > knee) {
        if (st->limEnv < ceiling) {
            float excess = st->limEnv - knee;
            float compressed = knee + excess / (1.0f + excess * 2.2f);
            targetGain = compressed / st->limEnv;
        } else {
            targetGain = ceiling / st->limEnv;
        }
    }

    if (targetGain < st->limGain) {
        st->limGain += 0.65f * (targetGain - st->limGain);
    } else {
        st->limGain += relCoeff * (targetGain - st->limGain);
    }

    // Hard instantaneous overshoot protection so peaks never slam into the ceiling
    if (peak * st->limGain > 0.945f && peak > 1e-6f) {
        st->limGain = 0.945f / peak;
    }

    *ioL = IVLSafetyCeiling(l * st->limGain);
    *ioR = IVLSafetyCeiling(r * st->limGain);
}

static void IVLProcessAudioBufferList(AudioBufferList *ioData, UInt32 inNumberFrames, IVLFilterState *fltPtr, int pathID) {
    if (!ioData || ioData->mNumberBuffers == 0 || inNumberFrames == 0) return;

    atomic_fetch_add_explicit(&gProcessedCalls, 1, memory_order_relaxed);
    atomic_store_explicit(&gActivePath, pathID, memory_order_relaxed);

    BOOL kOn = atomic_load_explicit(&gKaraokeOn, memory_order_relaxed);
    BOOL bOn = atomic_load_explicit(&gBoostOn, memory_order_relaxed);
    BOOL eqOn = atomic_load_explicit(&gEQOn, memory_order_relaxed);
    if (!kOn && !bOn && !eqOn) return;

    float kStr = kOn ? atomic_load_explicit(&gKaraokeStrength, memory_order_relaxed) : 0.0f;
    float gain = bOn ? atomic_load_explicit(&gBoostGain, memory_order_relaxed) : 1.0f;
    if (kOn) gain *= 1.14f; // Subtle makeup gain for center energy removed with vocals

    const IVLEQBank *eqBank = eqOn ? &gEQBanks[atomic_load_explicit(&gActiveEQBank, memory_order_acquire) & 1] : NULL;
    IVLFilterState localFlt = {0};
    IVLFilterState *st = fltPtr ?: &localFlt;
    if (!st->limInited) {
        st->limGain = 1.0f;
        st->limEnv = 0.0f;
        st->limInited = YES;
    }
    float sr = (float)atomic_load_explicit(&gSampleRateHz, memory_order_relaxed);
    if (sr < 8000.0f) sr = 48000.0f;
    // ~115 ms smooth release envelope
    float relCoeff = 1.0f - expf(-1.0f / (0.115f * sr));

    // Band-limited vocal isolator: preserves bass/kick (< ~180 Hz) AND crisp hi-hats (> ~6.8 kHz)
    const float alphaLow = 0.023f;
    const float alphaHigh = 0.59f;
    float lpLow = st->lpLow;
    float lpHigh = st->lpHigh;

    // 1. Non-interleaved stereo Float32
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
                    lpLow += alphaLow * (mid - lpLow);
                    lpHigh += alphaHigh * (mid - lpHigh);
                    float vocal = lpHigh - lpLow;
                    l -= kStr * vocal;
                    r -= kStr * vocal;
                }
                if (eqBank) IVLApplyEQSampleStereo(eqBank, st, &l, &r);
                IVLApplyDynamicBoostStereo(st, gain, relCoeff, &l, &r);
                L[i] = l;
                R[i] = r;
            }
            st->lpLow = lpLow; st->lpHigh = lpHigh;
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
                    lpLow += alphaLow * (mid - lpLow);
                    lpHigh += alphaHigh * (mid - lpHigh);
                    float vocal = lpHigh - lpLow;
                    l -= kStr * vocal;
                    r -= kStr * vocal;
                }
                if (eqBank) IVLApplyEQSampleStereo(eqBank, st, &l, &r);
                IVLApplyDynamicBoostStereo(st, gain, relCoeff, &l, &r);
                buf[i * 2] = l;
                buf[i * 2 + 1] = r;
            }
            st->lpLow = lpLow; st->lpHigh = lpHigh;
            return;
        }
    }

    // 3. Mono Float32
    if (ioData->mNumberBuffers == 1 &&
        ioData->mBuffers[0].mNumberChannels == 1 &&
        ioData->mBuffers[0].mDataByteSize >= inNumberFrames * sizeof(float)) {
        float *buf = (float *)ioData->mBuffers[0].mData;
        if (buf && (bOn || eqBank)) {
            for (UInt32 i = 0; i < inNumberFrames; i++) {
                float m = buf[i], dummy = m;
                if (eqBank) IVLApplyEQSampleStereo(eqBank, st, &m, &dummy);
                IVLApplyDynamicBoostStereo(st, gain, relCoeff, &m, &dummy);
                buf[i] = m;
            }
            return;
        }
    }

    // 4. Interleaved stereo Int16
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
                    lpLow += alphaLow * (mid - lpLow);
                    lpHigh += alphaHigh * (mid - lpHigh);
                    float vocal = lpHigh - lpLow;
                    l -= kStr * vocal;
                    r -= kStr * vocal;
                }
                if (eqBank) IVLApplyEQSampleStereo(eqBank, st, &l, &r);
                IVLApplyDynamicBoostStereo(st, gain, relCoeff, &l, &r);
                l = fmaxf(-1.0f, fminf(1.0f, l));
                r = fmaxf(-1.0f, fminf(1.0f, r));
                buf[i * 2] = (int16_t)(l * 32767.0f);
                buf[i * 2 + 1] = (int16_t)(r * 32767.0f);
            }
            st->lpLow = lpLow; st->lpHigh = lpHigh;
        }
    }
}

#pragma mark - Low-level CoreAudio C Hooks (fallback paths)

static OSStatus IVLDSPRenderCallback(void *inRefCon,
                                     AudioUnitRenderActionFlags *ioActionFlags,
                                     const AudioTimeStamp *inTimeStamp,
                                     UInt32 inBusNumber,
                                     UInt32 inNumberFrames,
                                     AudioBufferList *ioData) {
    IVLUnitEntry *entry = (IVLUnitEntry *)inRefCon;
    if (!entry || !entry->origProc) return noErr;
    OSStatus st = entry->origProc(entry->origRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    if (st == noErr) IVLProcessAudioBufferList(ioData, inNumberFrames, &entry->flt, 1);
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
            slot->flt.lpLow = 0.0f;
            slot->flt.lpHigh = 0.0f;
            pthread_mutex_unlock(&gUnitsLock);

            AURenderCallbackStruct wrapped;
            wrapped.inputProc = IVLDSPRenderCallback;
            wrapped.inputProcRefCon = slot;
            return orig(inUnit, inID, inScope, inElement, &wrapped, sizeof(wrapped));
        }
    }
    return orig(inUnit, inID, inScope, inElement, inData, inDataSize);
}

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
    if (st == noErr && atomic_load_explicit(&gActivePath, memory_order_relaxed) != 1) {
        IVLProcessAudioBufferList(ioData, inNumberFrames, &gGlobalFilter, 2);
    }
    return st;
}

typedef OSStatus (*IVLAudioQueueEnqueueFn)(AudioQueueRef, AudioQueueBufferRef, UInt32, const AudioStreamPacketDescription *);
static IVLAudioQueueEnqueueFn gOrigAudioQueueEnqueue = NULL;

static OSStatus IVLHookAudioQueueEnqueueBuffer(AudioQueueRef inAQ,
                                               AudioQueueBufferRef inBuffer,
                                               UInt32 inNumPacketDescs,
                                               const AudioStreamPacketDescription *inPacketDescs) {
    IVLAudioQueueEnqueueFn orig = gOrigAudioQueueEnqueue ?: AudioQueueEnqueueBuffer;
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
            if (frames > 0) IVLProcessAudioBufferList(&abl, frames, &gGlobalFilter, 3);
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

#pragma mark - Interactive 6-Band Equalizer Graph + Audio DSP Controller

static const double kIVLEQPresets[6][kIVLEQBandCount] = {
    {  0.0,  0.0,  0.0,  0.0,  0.0,  0.0 }, // 0: Flat
    {  6.5,  5.0,  1.5,  0.0,  0.0,  0.0 }, // 1: Bass Boost
    {  0.0,  0.0,  0.0,  1.5,  4.5,  6.5 }, // 2: Treble Boost
    { -2.0, -1.0,  2.0,  5.0,  3.5,  1.0 }, // 3: Vocal
    {  5.5,  3.5, -1.5, -1.0,  3.5,  5.5 }, // 4: Rock / V
    {  3.0,  2.0,  0.5,  1.5,  3.0,  3.5 }, // 5: Acoustic
};

static NSString *IVLEQPresetName(NSInteger idx) {
    switch (idx) {
        case 0: return IVLLoc(@"eq_flat");
        case 1: return IVLLoc(@"eq_bass");
        case 2: return IVLLoc(@"eq_treble");
        case 3: return IVLLoc(@"eq_vocal");
        case 4: return IVLLoc(@"eq_rock");
        case 5: return IVLLoc(@"eq_acoustic");
        default: return IVLLoc(@"eq_custom");
    }
}

static void IVLReadEffectiveEQBands(double outBands[kIVLEQBandCount]) {
    NSInteger preset = [IVLSettings integerForKey:IVLKeyEQPreset];
    if (preset >= 0 && preset < 6) {
        for (int i = 0; i < kIVLEQBandCount; i++) outBands[i] = kIVLEQPresets[preset][i];
        return;
    }
    NSArray *arr = [IVLSettings objectForKey:IVLKeyEQBands];
    for (int i = 0; i < kIVLEQBandCount; i++) {
        double v = ([arr isKindOfClass:[NSArray class]] && i < (int)arr.count) ? [arr[i] doubleValue] : 0.0;
        outBands[i] = fmax(-12.0, fmin(12.0, v));
    }
}

@interface IVLEQGraphView : UIView
@property (nonatomic, copy) void (^onBandsChanged)(BOOL finished);
- (void)reloadFromSettings;
@end

@implementation IVLEQGraphView {
    double _gains[kIVLEQBandCount];
    int _activeBand;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.contentMode = UIViewContentModeRedraw;
        _activeBand = -1;
        [self reloadFromSettings];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        pan.delaysTouchesBegan = NO;
        [self addGestureRecognizer:pan];

        UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)];
        doubleTap.numberOfTapsRequired = 2;
        [self addGestureRecognizer:doubleTap];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
        [tap requireGestureRecognizerToFail:doubleTap];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)reloadFromSettings {
    IVLReadEffectiveEQBands(_gains);
    [self setNeedsDisplay];
}

- (int)bandIndexForX:(CGFloat)x {
    CGFloat w = self.bounds.size.width;
    if (w <= 0) return 0;
    int idx = (int)floor((x / w) * kIVLEQBandCount);
    if (idx < 0) idx = 0;
    if (idx >= kIVLEQBandCount) idx = kIVLEQBandCount - 1;
    return idx;
}

- (double)gainForY:(CGFloat)y {
    CGFloat topPad = 26.0, botPad = 26.0;
    CGFloat trackH = MAX(40.0, self.bounds.size.height - topPad - botPad);
    double norm = 1.0 - (double)((y - topPad) / trackH); // 1.0 = +12dB, 0.0 = -12dB
    double db = (norm * 24.0) - 12.0;
    db = round(fmax(-12.0, fmin(12.0, db)) * 2.0) / 2.0; // 0.5 dB steps
    if (fabs(db) < 0.4) db = 0.0;
    return db;
}

- (void)commitBandsFinished:(BOOL)finished {
    if (![IVLSettings boolForKey:IVLKeyEQEnabled]) {
        [IVLSettings setBool:YES forKey:IVLKeyEQEnabled];
    }
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:kIVLEQBandCount];
    for (int i = 0; i < kIVLEQBandCount; i++) [arr addObject:@(_gains[i])];
    [IVLSettings setObject:@6 forKey:IVLKeyEQPreset];
    [IVLSettings setObject:arr forKey:IVLKeyEQBands];
    [self setNeedsDisplay];
    if (self.onBandsChanged) self.onBandsChanged(finished);
}

- (void)handlePan:(UIPanGestureRecognizer *)gr {
    CGPoint pt = [gr locationInView:self];
    if (gr.state == UIGestureRecognizerStateBegan) {
        _activeBand = [self bandIndexForX:pt.x];
    }
    if (_activeBand >= 0 && _activeBand < kIVLEQBandCount) {
        _gains[_activeBand] = [self gainForY:pt.y];
        BOOL ended = (gr.state == UIGestureRecognizerStateEnded || gr.state == UIGestureRecognizerStateCancelled);
        [self commitBandsFinished:ended];
        if (ended) _activeBand = -1;
    }
}

- (void)handleTap:(UITapGestureRecognizer *)gr {
    CGPoint pt = [gr locationInView:self];
    int b = [self bandIndexForX:pt.x];
    _gains[b] = [self gainForY:pt.y];
    [self commitBandsFinished:YES];
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)gr {
    CGPoint pt = [gr locationInView:self];
    int b = [self bandIndexForX:pt.x];
    _gains[b] = 0.0;
    [self commitBandsFinished:YES];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    if (w <= 10 || h <= 40) return;

    BOOL eqOn = [IVLSettings boolForKey:IVLKeyEQEnabled];
    UIColor *accent = eqOn ? ([IVLTheme accentColor] ?: UIColor.systemPinkColor) : [UIColor colorWithWhite:0.55 alpha:0.7];
    CGFloat topPad = 26.0, botPad = 26.0;
    CGFloat trackH = h - topPad - botPad;
    CGFloat midY = topPad + trackH * 0.5;
    CGFloat colW = w / kIVLEQBandCount;

    // 0 dB & ±12 dB reference lines
    CGContextSetLineWidth(ctx, 1.0);
    [[UIColor colorWithWhite:1 alpha:0.08] setStroke];
    CGContextMoveToPoint(ctx, 8, topPad); CGContextAddLineToPoint(ctx, w - 8, topPad);
    CGContextMoveToPoint(ctx, 8, topPad + trackH); CGContextAddLineToPoint(ctx, w - 8, topPad + trackH);
    CGContextStrokePath(ctx);

    [[UIColor colorWithWhite:1 alpha:0.18] setStroke];
    CGFloat dash[2] = { 4.0, 4.0 };
    CGContextSaveGState(ctx);
    CGContextSetLineDash(ctx, 0, dash, 2);
    CGContextMoveToPoint(ctx, 8, midY); CGContextAddLineToPoint(ctx, w - 8, midY);
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);

    CGPoint pts[kIVLEQBandCount];
    for (int i = 0; i < kIVLEQBandCount; i++) {
        CGFloat cx = colW * (i + 0.5);
        CGFloat norm = (CGFloat)((_gains[i] + 12.0) / 24.0);
        CGFloat cy = topPad + trackH * (1.0 - norm);
        pts[i] = CGPointMake(cx, cy);

        // Vertical fader rail
        UIBezierPath *rail = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(cx - 1.5, topPad, 3.0, trackH) cornerRadius:1.5];
        [[UIColor colorWithWhite:1 alpha:0.12] setFill];
        [rail fill];

        // Active fill bar from 0 dB to thumb
        CGFloat barTop = MIN(midY, cy), barH = fabs(cy - midY);
        if (barH > 1.0) {
            UIBezierPath *bar = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(cx - 2.0, barTop, 4.0, barH) cornerRadius:2.0];
            [[accent colorWithAlphaComponent:0.65] setFill];
            [bar fill];
        }
    }

    // Smooth cubic response curve across the 6 bands
    UIBezierPath *curve = [UIBezierPath bezierPath];
    [curve moveToPoint:pts[0]];
    for (int i = 0; i < kIVLEQBandCount - 1; i++) {
        CGFloat midX = (pts[i].x + pts[i + 1].x) * 0.5;
        [curve addCurveToPoint:pts[i + 1] controlPoint1:CGPointMake(midX, pts[i].y) controlPoint2:CGPointMake(midX, pts[i + 1].y)];
    }
    curve.lineWidth = 2.2;
    [[accent colorWithAlphaComponent:0.9] setStroke];
    [curve stroke];

    // Thumb knobs + dB readout + Hz labels
    static NSString *const kLabels[kIVLEQBandCount] = { @"60", @"150", @"400", @"1K", @"2.4K", @"12K" };
    NSDictionary *valAttrs = @{
        NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:10.5 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:(eqOn ? 0.85 : 0.45)]
    };
    NSDictionary *hzAttrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:10.5 weight:UIFontWeightMedium],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.50]
    };

    for (int i = 0; i < kIVLEQBandCount; i++) {
        CGPoint p = pts[i];
        CGRect knob = CGRectMake(p.x - 8.5, p.y - 8.5, 17.0, 17.0);
        [[UIColor colorWithWhite:0.12 alpha:1.0] setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectInset(knob, -1.5, -1.5)] fill];
        [(eqOn ? UIColor.whiteColor : [UIColor colorWithWhite:0.65 alpha:1.0]) setFill];
        [[UIBezierPath bezierPathWithOvalInRect:knob] fill];
        [accent setStroke];
        UIBezierPath *ring = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(knob, 1.5, 1.5)];
        ring.lineWidth = 2.0;
        [ring stroke];

        NSString *dbStr = (fabs(_gains[i]) < 0.05) ? @"0" : [NSString stringWithFormat:@"%+.1f", _gains[i]];
        CGSize dbSz = [dbStr sizeWithAttributes:valAttrs];
        [dbStr drawAtPoint:CGPointMake(p.x - dbSz.width * 0.5, 6.0) withAttributes:valAttrs];

        CGSize hzSz = [kLabels[i] sizeWithAttributes:hzAttrs];
        [kLabels[i] drawAtPoint:CGPointMake(p.x - hzSz.width * 0.5, h - botPad + 7.0) withAttributes:hzAttrs];
    }
}

@end

@interface IVLAudioSheetViewController : UITableViewController
@property (nonatomic, assign) BOOL pushedInSettings;
@end

@implementation IVLAudioSheetViewController {
    NSTimer *_statusTimer;
    __weak IVLEQGraphView *_eqGraph;
    __weak UIButton *_presetBtn;
    __weak UISwitch *_eqSwitch;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = IVLLoc(@"sec_audio");
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    if (!_pushedInSettings) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    }
    _statusTimer = [NSTimer scheduledTimerWithTimeInterval:0.8 target:self selector:@selector(refreshStatus) userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_statusTimer invalidate];
    _statusTimer = nil;
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)refreshStatus {
    UITableViewCell *c = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:3]];
    if (c) c.detailTextLabel.text = [IVLAudioDSP statusText];
}

- (void)rebuildPresetMenuOnButton:(UIButton *)btn {
    if (!btn) return;
    NSInteger cur = [IVLSettings integerForKey:IVLKeyEQPreset];
    [btn setTitle:[NSString stringWithFormat:@"%@ ▾", IVLEQPresetName(cur)] forState:UIControlStateNormal];

    __weak typeof(self) ws = self;
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
    for (NSInteger i = 0; i <= 6; i++) {
        if (i == 6 && cur != 6) continue;
        UIAction *a = [UIAction actionWithTitle:IVLEQPresetName(i) image:nil identifier:nil handler:^(UIAction *act) {
            __strong typeof(ws) ss = ws;
            if (!ss) return;
            [IVLSettings setObject:@(i) forKey:IVLKeyEQPreset];
            if (i != 0 && ![IVLSettings boolForKey:IVLKeyEQEnabled]) {
                [IVLSettings setBool:YES forKey:IVLKeyEQEnabled];
                ss->_eqSwitch.on = YES;
            }
            [ss->_eqGraph reloadFromSettings];
            [ss rebuildPresetMenuOnButton:ss->_presetBtn];
        }];
        a.state = (i == cur) ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:a];
    }
    btn.menu = [UIMenu menuWithTitle:@"" children:actions];
    btn.showsMenuAsPrimaryAction = YES;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 3 ? 1 : 2; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return IVLLoc(@"footer_equalizer");
    if (section == 1) return IVLLoc(@"footer_karaoke_mode");
    if (section == 2) return IVLLoc(@"footer_volume_boost");
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 3) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        c.textLabel.text = IVLLoc(@"status");
        c.detailTextLabel.text = [IVLAudioDSP statusText];
        return c;
    }

    // Section 0: Custom 6-Band Equalizer
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            c.textLabel.text = IVLLoc(@"equalizer");

            UIButton *pBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            pBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
            [pBtn setTitleColor:([IVLTheme accentColor] ?: UIColor.systemPinkColor) forState:UIControlStateNormal];
            _presetBtn = pBtn;
            [self rebuildPresetMenuOnButton:pBtn];

            UISwitch *sw = [UISwitch new];
            sw.on = [IVLSettings boolForKey:IVLKeyEQEnabled];
            _eqSwitch = sw;
            __weak typeof(self) ws = self;
            [sw addAction:[UIAction actionWithHandler:^(UIAction *a) {
                [IVLSettings setBool:((UISwitch *)a.sender).on forKey:IVLKeyEQEnabled];
                __strong typeof(ws) ss = ws;
                if (ss) [ss->_eqGraph setNeedsDisplay];
            }] forControlEvents:UIControlEventValueChanged];

            UIStackView *acc = [[UIStackView alloc] initWithArrangedSubviews:@[pBtn, sw]];
            acc.axis = UILayoutConstraintAxisHorizontal;
            acc.spacing = 12;
            acc.alignment = UIStackViewAlignmentCenter;
            [acc sizeToFit];
            c.accessoryView = acc;
            return c;
        }

        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        IVLEQGraphView *graph = [[IVLEQGraphView alloc] initWithFrame:CGRectZero];
        graph.translatesAutoresizingMaskIntoConstraints = NO;
        _eqGraph = graph;
        __weak typeof(self) ws = self;
        graph.onBandsChanged = ^(__unused BOOL finished) {
            __strong typeof(ws) ss = ws;
            if (!ss) return;
            ss->_eqSwitch.on = [IVLSettings boolForKey:IVLKeyEQEnabled];
            [ss rebuildPresetMenuOnButton:ss->_presetBtn];
        };
        [c.contentView addSubview:graph];
        [NSLayoutConstraint activateConstraints:@[
            [graph.leadingAnchor constraintEqualToAnchor:c.contentView.leadingAnchor constant:6],
            [graph.trailingAnchor constraintEqualToAnchor:c.contentView.trailingAnchor constant:-6],
            [graph.topAnchor constraintEqualToAnchor:c.contentView.topAnchor constant:4],
            [graph.bottomAnchor constraintEqualToAnchor:c.contentView.bottomAnchor constant:-4],
            [graph.heightAnchor constraintEqualToConstant:196],
        ]];
        return c;
    }

    // Sections 1 & 2: Karaoke & Volume Boost
    BOOL isKaraoke = (indexPath.section == 1);
    if (indexPath.row == 0) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        NSString *key = isKaraoke ? IVLKeyKaraokeMode : IVLKeyVolumeBoost;
        c.textLabel.text = isKaraoke ? IVLLoc(@"karaoke_mode") : IVLLoc(@"volume_boost");
        UISwitch *sw = [UISwitch new];
        sw.on = [IVLSettings boolForKey:key];
        [sw addAction:[UIAction actionWithHandler:^(UIAction *a) {
            [IVLSettings setBool:((UISwitch *)a.sender).on forKey:key];
        }] forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
        return c;
    }
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    NSString *key = isKaraoke ? IVLKeyKaraokeStrength : IVLKeyVolumeBoostLevel;
    double minV = isKaraoke ? 0.0 : 100.0;
    double maxV = isKaraoke ? 100.0 : 300.0;
    double step = isKaraoke ? 5.0 : 10.0;
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
        double v = round(((UISlider *)a.sender).value / step) * step;
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

#pragma mark - Real-time Per-Packet AudioConverter Decoder (Opus / AAC / HE-AAC -> Float32 PCM)

#define kIVLNeedMoreInput ((OSStatus)0x6E6D706B) // 'nmpk' — prevents AudioConverter from marking permanent EOF

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
    const uint8_t *pktBytes;
    UInt32 pktLen;
    UInt32 channels;
    UInt32 varFrames;
    BOOL consumed;
    AudioStreamPacketDescription desc;
} IVLSinglePacketFeed;

// RFC 6716 Section 3.1: exact Opus packet sample count at 48 kHz
static UInt32 IVLOpusPacketFrames(const uint8_t *pkt, UInt32 len) {
    if (!pkt || len == 0) return 960;
    uint8_t toc = pkt[0];
    uint8_t cfg = toc >> 3;
    UInt32 frameSize = 960;
    if (cfg < 12) {
        static const UInt32 kSilk[4] = { 480, 960, 1920, 2880 };
        frameSize = kSilk[cfg & 3];
    } else if (cfg < 16) {
        frameSize = (cfg & 1) ? 960 : 480;
    } else {
        static const UInt32 kCelt[4] = { 120, 240, 480, 960 };
        frameSize = kCelt[cfg & 3];
    }
    uint8_t c = toc & 3;
    UInt32 count = 1;
    if (c == 1 || c == 2) count = 2;
    else if (c == 3) count = (len >= 2 && (pkt[1] & 0x3F) > 0) ? (pkt[1] & 0x3F) : 1;
    return frameSize * count;
}

static OSStatus IVLSinglePacketInputProc(AudioConverterRef inAudioConverter,
                                         UInt32 *ioNumberDataPackets,
                                         AudioBufferList *ioData,
                                         AudioStreamPacketDescription **outDataPacketDescription,
                                         void *inUserData) {
    IVLSinglePacketFeed *feed = (IVLSinglePacketFeed *)inUserData;
    if (!feed || feed->consumed || feed->pktLen == 0) {
        *ioNumberDataPackets = 0;
        return kIVLNeedMoreInput;
    }
    feed->desc.mStartOffset = 0;
    feed->desc.mVariableFramesInPacket = feed->varFrames;
    feed->desc.mDataByteSize = feed->pktLen;

    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mNumberChannels = feed->channels;
    ioData->mBuffers[0].mData = (void *)feed->pktBytes;
    ioData->mBuffers[0].mDataByteSize = feed->pktLen;
    if (outDataPacketDescription) *outDataPacketDescription = &feed->desc;

    feed->consumed = YES;
    *ioNumberDataPackets = 1;
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

    UInt32 outCh = (inASBD->mChannelsPerFrame >= 1 && inASBD->mChannelsPerFrame <= 2) ? inASBD->mChannelsPerFrame : 2;
    Float64 outSR = (inASBD->mSampleRate > 0) ? inASBD->mSampleRate : 48000.0;

    AudioStreamBasicDescription outASBD;
    memset(&outASBD, 0, sizeof(outASBD));
    outASBD.mSampleRate = outSR;
    outASBD.mFormatID = kAudioFormatLinearPCM;
    outASBD.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    outASBD.mBitsPerChannel = 32;
    outASBD.mChannelsPerFrame = outCh;
    outASBD.mBytesPerFrame = outCh * sizeof(float);
    outASBD.mFramesPerPacket = 1;
    outASBD.mBytesPerPacket = outASBD.mBytesPerFrame;

    AudioConverterRef conv = NULL;
    OSStatus st = AudioConverterNew(inASBD, &outASBD, &conv);
    if ((st != noErr || !conv) && inASBD->mFormatID == kAudioFormatOpus) {
        AudioStreamBasicDescription fixedIn = *inASBD;
        if (fixedIn.mSampleRate <= 0) fixedIn.mSampleRate = 48000.0;
        if (fixedIn.mChannelsPerFrame == 0) fixedIn.mChannelsPerFrame = 2;
        if (fixedIn.mFramesPerPacket == 0) fixedIn.mFramesPerPacket = 960;
        outASBD.mSampleRate = fixedIn.mSampleRate;
        outASBD.mChannelsPerFrame = fixedIn.mChannelsPerFrame;
        outASBD.mBytesPerFrame = outASBD.mChannelsPerFrame * sizeof(float);
        outASBD.mBytesPerPacket = outASBD.mBytesPerFrame;
        st = AudioConverterNew(&fixedIn, &outASBD, &conv);
    }
    if (st != noErr || !conv) {
        AudioClassDescription swDesc = { kAudioDecoderComponentType, inASBD->mFormatID, kAppleSoftwareAudioCodecManufacturer };
        st = AudioConverterNewSpecific(inASBD, &outASBD, 1, &swDesc, &conv);
    }
    if (st != noErr || !conv) {
        atomic_store_explicit(&gLastStage, 2, memory_order_relaxed);
        atomic_store_explicit(&gLastError, (int)st, memory_order_relaxed);
        return NO;
    }

    if (cPtr && cSize > 0) {
        AudioConverterSetProperty(conv, kAudioConverterDecompressionMagicCookie, (UInt32)cSize, cPtr);
        gDecoder.cookie = malloc(cSize);
        if (gDecoder.cookie) { memcpy(gDecoder.cookie, cPtr, cSize); gDecoder.cookieSize = cSize; }
    } else if (inASBD->mFormatID == kAudioFormatOpus) {
        uint8_t opusHead[19] = {
            'O','p','u','s','H','e','a','d',
            1, (uint8_t)outASBD.mChannelsPerFrame,
            0x38, 0x01,
            0x80, 0xBB, 0x00, 0x00,
            0x00, 0x00, 0
        };
        AudioConverterSetProperty(conv, kAudioConverterDecompressionMagicCookie, sizeof(opusHead), opusHead);
    }

    CMFormatDescriptionRef outFmt = NULL;
    OSStatus fmtSt = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &outASBD, 0, NULL, 0, NULL, NULL, &outFmt);
    if (fmtSt != noErr || !outFmt) {
        AudioConverterDispose(conv);
        atomic_store_explicit(&gLastStage, 2, memory_order_relaxed);
        atomic_store_explicit(&gLastError, (int)fmtSt, memory_order_relaxed);
        return NO;
    }

    gDecoder.converter = conv;
    gDecoder.inASBD = *inASBD;
    gDecoder.outASBD = outASBD;
    gDecoder.outFmt = outFmt;

    int newSR = (int)round(outASBD.mSampleRate);
    if (newSR > 8000 && newSR != atomic_load_explicit(&gSampleRateHz, memory_order_relaxed)) {
        atomic_store_explicit(&gSampleRateHz, newSR, memory_order_relaxed);
        int nextIdx = (atomic_load_explicit(&gActiveEQBank, memory_order_relaxed) + 1) & 1;
        IVLBuildEQBank(&gEQBanks[nextIdx], gCurrentEQGainsDB, outASBD.mSampleRate);
        atomic_store_explicit(&gActiveEQBank, nextIdx, memory_order_release);
    }
    return YES;
}

static NSString *IVLFourCCString(uint32_t fcc) {
    if (fcc == 0) return @"";
    char c[5];
    c[0] = (char)((fcc >> 24) & 0xFF);
    c[1] = (char)((fcc >> 16) & 0xFF);
    c[2] = (char)((fcc >> 8) & 0xFF);
    c[3] = (char)(fcc & 0xFF);
    c[4] = 0;
    for (int i = 0; i < 4; i++) {
        if (c[i] < 32 || c[i] > 126) return [NSString stringWithFormat:@"0x%08x", fcc];
    }
    return [[NSString stringWithUTF8String:c] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

#pragma mark - Manager

@implementation IVLAudioDSP {
    BOOL _started;
    BOOL _prevKaraokeOn;
    double _prevKaraokeStrength;
    BOOL _prevBoostOn;
    double _prevBoostLevel;
    BOOL _prevEQOn;
    double _prevEQBands[kIVLEQBandCount];
    uint64_t _reseekToken;
}

+ (instancetype)shared {
    static IVLAudioDSP *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [self new]; });
    return s;
}

+ (void)registerRenderer:(id)renderer {
    if (!renderer) return;
    BOOL isNew = NO;
    pthread_mutex_lock(&gRenderersLock);
    if (!gRenderers) gRenderers = [NSHashTable weakObjectsHashTable];
    if (![gRenderers containsObject:renderer]) {
        [gRenderers addObject:renderer];
        isNew = YES;
    }
    pthread_mutex_unlock(&gRenderersLock);

    if (isNew && !objc_getAssociatedObject(renderer, kIVLBaseVolumeKey)) {
        float cur = 1.0f;
        if ([renderer respondsToSelector:@selector(volume)]) {
            cur = [(AVPlayer *)renderer volume];
            if (cur <= 0.001f || cur > 1.0f) cur = 1.0f;
        }
        objc_setAssociatedObject(renderer, kIVLBaseVolumeKey, @(cur), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (atomic_load_explicit(&gBoostOn, memory_order_relaxed) && cur < 0.999f && [renderer respondsToSelector:@selector(setVolume:)]) {
            tReapplyingVolume = YES;
            [(AVPlayer *)renderer setVolume:cur];
            tReapplyingVolume = NO;
        }
    }
}

+ (float)scaledVolumeForRenderer:(id)renderer requestedVolume:(float)volume {
    if (renderer) {
        [self registerRenderer:renderer];
        if (!tReapplyingVolume) {
            objc_setAssociatedObject(renderer, kIVLBaseVolumeKey, @(volume), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    if (atomic_load_explicit(&gBoostOn, memory_order_relaxed) && volume > 0.0001f) {
        // Lift YouTube's loudness-normalized renderer attenuation up to full 1.0 headroom;
        // PCM DSP simultaneously applies the rest of the gain above 1.0 with soft-clipping.
        float gain = atomic_load_explicit(&gBoostGain, memory_order_relaxed);
        return fminf(1.0f, volume * gain);
    }
    return volume;
}

- (void)reapplyVolumesToAllRenderers {
    pthread_mutex_lock(&gRenderersLock);
    NSArray *all = gRenderers ? gRenderers.allObjects : @[];
    pthread_mutex_unlock(&gRenderersLock);

    for (id r in all) {
        if (![r respondsToSelector:@selector(setVolume:)]) continue;
        NSNumber *base = objc_getAssociatedObject(r, kIVLBaseVolumeKey);
        float baseVol = base ? base.floatValue : 1.0f;
        tReapplyingVolume = YES;
        [(AVPlayer *)r setVolume:baseVol];
        tReapplyingVolume = NO;
    }
}

+ (void)noteRendererFailure:(int)errCode {
    atomic_store_explicit(&gLastStage, 4, memory_order_relaxed);
    atomic_store_explicit(&gLastError, errCode, memory_order_relaxed);
    atomic_fetch_add_explicit(&gSBARFailCount, 1, memory_order_relaxed);
}

+ (NSString *)statusText {
    uint64_t calls = atomic_load_explicit(&gProcessedCalls, memory_order_relaxed);
    int path = atomic_load_explicit(&gActivePath, memory_order_relaxed);
    int hits = atomic_load_explicit(&gRebindHits, memory_order_relaxed);
    int stage = atomic_load_explicit(&gLastStage, memory_order_relaxed);
    int err = atomic_load_explicit(&gLastError, memory_order_relaxed);
    NSString *codec = IVLFourCCString(atomic_load_explicit(&gLastFormatID, memory_order_relaxed));

    if (stage != 0 && (atomic_load_explicit(&gKaraokeOn, memory_order_relaxed) || atomic_load_explicit(&gBoostOn, memory_order_relaxed) || atomic_load_explicit(&gEQOn, memory_order_relaxed))) {
        return [NSString stringWithFormat:@"Err s%d:%d (%@)", stage, err, codec.length ? codec : @"?"];
    }
    if (calls > 0) {
        NSString *pName = @"DSP";
        switch (path) {
            case 1: pName = @"AudioUnit CB"; break;
            case 2: pName = @"AudioUnit"; break;
            case 3: pName = @"AudioQueue"; break;
            case 4: pName = @"AVAudioPlayerNode"; break;
            case 5: pName = @"SampleBuf PCM"; break;
            case 6: pName = @"AVPlayerTap"; break;
            case 7: pName = codec.length ? [NSString stringWithFormat:@"Passthrough · %@", codec] : @"SampleBuf (passthrough)"; break;
            case 8: pName = codec.length ? [NSString stringWithFormat:@"DSP · %@", codec] : @"SampleBuf DSP"; break;
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
        IVLProcessAudioBufferList(abl, buffer.frameLength, &gGlobalFilter, 4);
    }
}

+ (void)resetDecoder {
    pthread_mutex_lock(&gDecoderLock);
    if (gDecoder.converter) AudioConverterReset(gDecoder.converter);
    memset(&gGlobalFilter, 0, sizeof(gGlobalFilter));
    pthread_mutex_unlock(&gDecoderLock);
}

+ (CMSampleBufferRef)createProcessedSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!sampleBuffer) return NULL;
    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
    const AudioStreamBasicDescription *asbd = fmt ? CMAudioFormatDescriptionGetStreamBasicDescription(fmt) : NULL;
    if (!asbd) return NULL;

    atomic_store_explicit(&gLastFormatID, (uint32_t)asbd->mFormatID, memory_order_relaxed);

    // Linear PCM path (in-place)
    if (asbd->mFormatID == kAudioFormatLinearPCM) {
        CMBlockBufferRef blockBuf = NULL;
        AudioBufferList abl;
        OSStatus st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, NULL, &abl, sizeof(abl), NULL, NULL,
            kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &blockBuf);
        if (st == noErr) {
            UInt32 frames = (UInt32)CMSampleBufferGetNumSamples(sampleBuffer);
            if (frames > 0) IVLProcessAudioBufferList(&abl, frames, &gGlobalFilter, 5);
        }
        if (blockBuf) CFRelease(blockBuf);
        return NULL;
    }

    // Encoded audio path (Opus / AAC / HE-AAC): zero-cost passthrough when EQ, Karaoke & Boost are all OFF
    BOOL kOn = atomic_load_explicit(&gKaraokeOn, memory_order_relaxed);
    BOOL bOn = atomic_load_explicit(&gBoostOn, memory_order_relaxed);
    BOOL eqOn = atomic_load_explicit(&gEQOn, memory_order_relaxed);
    if (!kOn && !bOn && !eqOn) {
        atomic_fetch_add_explicit(&gProcessedCalls, 1, memory_order_relaxed);
        atomic_store_explicit(&gActivePath, 7, memory_order_relaxed);
        return NULL;
    }

    if (atomic_load_explicit(&gSBARFailCount, memory_order_relaxed) >= 4) {
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
        atomic_store_explicit(&gLastStage, 1, memory_order_relaxed);
        return NULL;
    }

    size_t pdSize = 0;
    AudioStreamPacketDescription *pktDescs = NULL;
    UInt32 numPackets = 1;
    if (CMSampleBufferGetAudioStreamPacketDescriptions(sampleBuffer, 0, NULL, &pdSize) == noErr &&
        pdSize >= sizeof(AudioStreamPacketDescription)) {
        pktDescs = (AudioStreamPacketDescription *)malloc(pdSize);
        if (pktDescs) {
            if (CMSampleBufferGetAudioStreamPacketDescriptions(sampleBuffer, pdSize, pktDescs, NULL) == noErr) {
                numPackets = (UInt32)(pdSize / sizeof(AudioStreamPacketDescription));
            } else {
                free(pktDescs);
                pktDescs = NULL;
            }
        }
    } else if (asbd->mBytesPerPacket > 0) {
        numPackets = (UInt32)MAX(1, totalLen / asbd->mBytesPerPacket);
    }

    BOOL isOpus = (asbd->mFormatID == kAudioFormatOpus);
    UInt32 maxFramesPerPkt = isOpus ? 5760 : MAX(2048U, asbd->mFramesPerPacket);
    UInt32 maxOutFrames = numPackets * maxFramesPerPkt + 2048;

    UInt32 totalDecoded = 0;
    UInt32 outCh = 2;
    float *pcmOut = NULL;
    CMFormatDescriptionRef outFmtRetained = NULL;

    pthread_mutex_lock(&gDecoderLock);
    if (IVLEnsureDecoderLocked(asbd, fmt)) {
        outCh = gDecoder.outASBD.mChannelsPerFrame;
        pcmOut = (float *)malloc((size_t)maxOutFrames * outCh * sizeof(float));
        if (pcmOut) {
            for (UInt32 p = 0; p < numPackets && totalDecoded < maxOutFrames; p++) {
                const uint8_t *pktPtr = rawBytes;
                UInt32 pktLen = (UInt32)totalLen;
                UInt32 pktFrames = isOpus ? 960 : (asbd->mFramesPerPacket > 0 ? asbd->mFramesPerPacket : 1024);

                if (pktDescs) {
                    AudioStreamPacketDescription d = pktDescs[p];
                    if ((size_t)d.mStartOffset + d.mDataByteSize > totalLen || d.mDataByteSize == 0) continue;
                    pktPtr = rawBytes + d.mStartOffset;
                    pktLen = d.mDataByteSize;
                    if (d.mVariableFramesInPacket > 0) pktFrames = d.mVariableFramesInPacket;
                    else if (isOpus) pktFrames = IVLOpusPacketFrames(pktPtr, pktLen);
                } else if (asbd->mBytesPerPacket > 0) {
                    pktPtr = rawBytes + (size_t)p * asbd->mBytesPerPacket;
                    pktLen = asbd->mBytesPerPacket;
                } else if (isOpus) {
                    pktFrames = IVLOpusPacketFrames(pktPtr, pktLen);
                }

                UInt32 avail = maxOutFrames - totalDecoded;
                UInt32 want = MIN(avail, MAX(pktFrames, isOpus ? pktFrames : 2048U));
                if (isOpus) want = MIN(avail, pktFrames);

                IVLSinglePacketFeed feed;
                memset(&feed, 0, sizeof(feed));
                feed.pktBytes = pktPtr;
                feed.pktLen = pktLen;
                feed.channels = outCh;
                feed.varFrames = pktFrames;
                feed.consumed = NO;

                AudioBufferList outABL;
                outABL.mNumberBuffers = 1;
                outABL.mBuffers[0].mNumberChannels = outCh;
                outABL.mBuffers[0].mData = pcmOut + ((size_t)totalDecoded * outCh);
                outABL.mBuffers[0].mDataByteSize = want * outCh * sizeof(float);

                OSStatus st = AudioConverterFillComplexBuffer(gDecoder.converter, IVLSinglePacketInputProc, &feed, &want, &outABL, NULL);
                if (want > 0) totalDecoded += want;
                if (st != noErr && st != kIVLNeedMoreInput) {
                    atomic_store_explicit(&gLastStage, 3, memory_order_relaxed);
                    atomic_store_explicit(&gLastError, (int)st, memory_order_relaxed);
                    break;
                }
            }

            if (totalDecoded > 0 && gDecoder.outFmt) {
                atomic_store_explicit(&gLastStage, 0, memory_order_relaxed);
                atomic_fetch_add_explicit(&gDecodedFramesTotal, totalDecoded, memory_order_relaxed);
                AudioBufferList dspABL;
                dspABL.mNumberBuffers = 1;
                dspABL.mBuffers[0].mNumberChannels = outCh;
                dspABL.mBuffers[0].mData = pcmOut;
                dspABL.mBuffers[0].mDataByteSize = totalDecoded * outCh * sizeof(float);
                IVLProcessAudioBufferList(&dspABL, totalDecoded, &gGlobalFilter, 8);
                outFmtRetained = (CMFormatDescriptionRef)CFRetain(gDecoder.outFmt);
            }
        }
    }
    pthread_mutex_unlock(&gDecoderLock);

    free(rawBytes);
    if (pktDescs) free(pktDescs);

    if (totalDecoded == 0 || !outFmtRetained || !pcmOut) {
        if (pcmOut) free(pcmOut);
        if (outFmtRetained) CFRelease(outFmtRetained);
        return NULL;
    }

    size_t finalBytes = (size_t)totalDecoded * outCh * sizeof(float);
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

    if (sbSt != noErr || !outSB) return NULL;

    // Preserve TrimDurationAtStart / TrimDurationAtEnd & DoNotDisplay seek preroll attachments
    CMPropagateAttachments(sampleBuffer, outSB);
    CFArrayRef inSampleAtts = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (inSampleAtts && CFArrayGetCount(inSampleAtts) > 0) {
        CFDictionaryRef d0 = (CFDictionaryRef)CFArrayGetValueAtIndex(inSampleAtts, 0);
        if (d0 && CFDictionaryGetValue(d0, kCMSampleAttachmentKey_DoNotDisplay) == kCFBooleanTrue) {
            CFArrayRef outSampleAtts = CMSampleBufferGetSampleAttachmentsArray(outSB, true);
            if (outSampleAtts && CFArrayGetCount(outSampleAtts) > 0) {
                CFMutableDictionaryRef outD0 = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(outSampleAtts, 0);
                if (outD0) CFDictionarySetValue(outD0, kCMSampleAttachmentKey_DoNotDisplay, kCFBooleanTrue);
            }
        }
    }
    return outSB;
}

static void IVLTapProcess(MTAudioProcessingTapRef tap,
                          CMItemCount numberFrames,
                          MTAudioProcessingTapFlags flags,
                          AudioBufferList *bufferListInOut,
                          CMItemCount *numberFramesOut,
                          MTAudioProcessingTapFlags *flagsOut) {
    OSStatus st = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, NULL, numberFramesOut);
    if (st == noErr && numberFramesOut && *numberFramesOut > 0) {
        IVLProcessAudioBufferList(bufferListInOut, (UInt32)(*numberFramesOut), &gGlobalFilter, 6);
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

+ (UIViewController *)createSettingsPageController {
    IVLAudioSheetViewController *vc = [IVLAudioSheetViewController new];
    vc.pushedInSettings = YES;
    return vc;
}

+ (void)presentQuickSheetFrom:(UIViewController *)vc {
    if (!vc) return;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[IVLAudioSheetViewController new]];
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sh = nav.sheetPresentationController;
        sh.detents = @[UISheetPresentationControllerDetent.largeDetent, UISheetPresentationControllerDetent.mediumDetent];
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
    [self applySettingsInitial:YES];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onSettingsChanged) name:IVLSettingsDidChangeNotification object:nil];
    _dyld_register_func_for_add_image(IVLRebindImage);
}

- (void)onSettingsChanged {
    [self applySettingsInitial:NO];
}

// AVSampleBufferAudioRenderer pre-buffers ~10-15s of compressed audio in mediaserverd.
// Seeking to the current timestamp flushes SBAR from RAM cache so DSP changes take effect in ~0.1s.
- (void)scheduleSBARFlushWithDelay:(NSTimeInterval)delay {
    int path = atomic_load_explicit(&gActivePath, memory_order_relaxed);
    if (path != 7 && path != 8) return;
    uint64_t tok = ++_reseekToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (tok != self->_reseekToken) return;
        YTPlayerViewController *p = (YTPlayerViewController *)[IVLPlaybackManager shared].player;
        if (!p) return;
        @try {
            if ([p respondsToSelector:@selector(currentVideoMediaTime)] && [p respondsToSelector:@selector(seekToTime:)]) {
                CGFloat t = [p currentVideoMediaTime];
                if (t >= 0) [p seekToTime:t];
            }
        } @catch (__unused id e) {}
    });
}

- (void)applySettingsInitial:(BOOL)initial {
    BOOL kOn = [IVLSettings boolForKey:IVLKeyKaraokeMode];
    double kStr = [IVLSettings doubleForKey:IVLKeyKaraokeStrength];
    if (kStr < 0 || kStr > 100) kStr = 85.0;

    BOOL bOn = [IVLSettings boolForKey:IVLKeyVolumeBoost];
    double bPct = [IVLSettings doubleForKey:IVLKeyVolumeBoostLevel];
    if (bPct < 100 || bPct > 300) bPct = 150.0;

    BOOL eqOn = [IVLSettings boolForKey:IVLKeyEQEnabled];
    double eqBands[kIVLEQBandCount];
    IVLReadEffectiveEQBands(eqBands);

    BOOL eqBandsDiff = NO;
    for (int i = 0; i < kIVLEQBandCount; i++) {
        if (fabs(eqBands[i] - _prevEQBands[i]) > 0.05) { eqBandsDiff = YES; break; }
    }

    BOOL toggleChanged = (!initial && (kOn != _prevKaraokeOn || bOn != _prevBoostOn || eqOn != _prevEQOn));
    BOOL sliderChanged = (!initial && (fabs(kStr - _prevKaraokeStrength) > 0.1 || fabs(bPct - _prevBoostLevel) > 0.1 || eqBandsDiff));

    _prevKaraokeOn = kOn;
    _prevKaraokeStrength = kStr;
    _prevBoostOn = bOn;
    _prevBoostLevel = bPct;
    _prevEQOn = eqOn;
    for (int i = 0; i < kIVLEQBandCount; i++) {
        _prevEQBands[i] = eqBands[i];
        gCurrentEQGainsDB[i] = eqBands[i];
    }

    int sr = atomic_load_explicit(&gSampleRateHz, memory_order_relaxed);
    int nextIdx = (atomic_load_explicit(&gActiveEQBank, memory_order_relaxed) + 1) & 1;
    IVLBuildEQBank(&gEQBanks[nextIdx], eqBands, (double)sr);
    atomic_store_explicit(&gActiveEQBank, nextIdx, memory_order_release);

    // Clean dynamic boost curve: 150% -> 1.64x, 200% -> 2.33x, 250% -> 3.06x, 300% -> 3.82x
    // Paired with the stereo-linked peak limiter, this raises perceived loudness without clipping.
    float gain = (bPct <= 100.0) ? 1.0f : powf((float)(bPct / 100.0), 1.22f);

    atomic_store_explicit(&gKaraokeOn, kOn, memory_order_relaxed);
    atomic_store_explicit(&gKaraokeStrength, (float)(kStr / 100.0), memory_order_relaxed);
    atomic_store_explicit(&gBoostOn, bOn, memory_order_relaxed);
    atomic_store_explicit(&gBoostGain, gain, memory_order_relaxed);
    atomic_store_explicit(&gEQOn, eqOn, memory_order_relaxed);

    if (toggleChanged) {
        atomic_store_explicit(&gSBARFailCount, 0, memory_order_relaxed);
        atomic_store_explicit(&gLastStage, 0, memory_order_relaxed);
    }

    if (toggleChanged || sliderChanged) {
        [self reapplyVolumesToAllRenderers];
        [self scheduleSBARFlushWithDelay:toggleChanged ? 0.04 : 0.28];
    }
}

@end
