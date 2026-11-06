#include "HALRender.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

/// Long enough that a pause, a play or either side of a seek doesn't click, short enough that it
/// still sounds immediate.
static const double fadeSeconds = 0.005;

// Fields marked "IO proc only" are touched by whichever thread runs the IO proc. CoreAudio starts
// and stops it with a happens-before edge, so they need no atomics.
struct HALRender {
    RingBuffer *source;
    HALRenderSampleKind samples;
    uint32_t bytesPerFrame;
    /// Frames from full gain to silence, or back.
    uint32_t fadeFrames;
    _Atomic uint64_t underrunBytes;
    _Atomic uint64_t consumedBytes;
    /// A sequence lock around `postedFrom` and `postedTo`, so the IO proc never pairs one
    /// discard's start with another's end: odd while the producer writes them.
    _Atomic uint32_t discardSequence;
    _Atomic uint64_t postedFrom;
    _Atomic uint64_t postedTo;
    _Atomic bool draining;
    /// The bits of a float, because C11 doesn't promise `_Atomic float` is lock-free.
    _Atomic uint32_t gainBits;
    /// Counts `HALRenderSetSilenced` changes: odd while silenced.
    _Atomic uint32_t silenceRequest;
    /// The silenced request the IO proc last finished its fade-out for.
    _Atomic uint32_t silentFor;
    /// IO proc only: the gain the last buffer ended at, the start of the next ramp.
    float appliedGain;
    /// IO proc only: the sequence number of the last discard it acted on.
    uint32_t discardSeen;
    /// IO proc only: the discard it is waiting to reach, if `discarding`.
    bool discarding;
    uint64_t discardFrom;
    uint64_t discardTo;
    /// IO proc only: set by a discard, cleared once a whole buffer comes from `source`.
    bool refilling;
    /// IO proc only: where the fade is, from 0 (silence) to `fadeFrames` (full gain, where no
    /// sample is touched).
    uint32_t fadeStep;
    /// IO proc only: whether it has run a cycle since the last start, so what a discard drops
    /// has been playing and fades out.
    bool live;
    /// IO proc only: frames a discard dropped, which fade out before the audio after it:
    /// `heldFrames` of them in `held`, played up to `heldPlayed`. While any are left, `fadeStep`
    /// equals how many, so the fade reaches silence on the last.
    uint8_t *held;
    uint32_t heldFrames;
    uint32_t heldPlayed;
};

static uint32_t bitsOf(float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof bits);
    return bits;
}

static float floatOf(uint32_t bits) {
    float value;
    memcpy(&value, &bits, sizeof value);
    return value;
}

uint32_t HALRenderFadeFrames(double sampleRateHz) {
    long frames = lround(sampleRateHz * fadeSeconds);
    return frames < 1 ? 1 : (uint32_t)frames;
}

HALRender *HALRenderCreate(RingBuffer *source, HALRenderSampleKind samples,
                           uint32_t bytesPerFrame, double sampleRateHz) {
    HALRender *render = malloc(sizeof *render);
    if (render == NULL) return NULL;
    render->fadeFrames = HALRenderFadeFrames(sampleRateHz);
    render->held = malloc((size_t)render->fadeFrames * bytesPerFrame);
    if (render->held == NULL) {
        free(render);
        return NULL;
    }
    render->source = source;
    render->samples = samples;
    render->bytesPerFrame = bytesPerFrame;
    atomic_init(&render->underrunBytes, 0);
    atomic_init(&render->consumedBytes, 0);
    atomic_init(&render->discardSequence, 0);
    atomic_init(&render->postedFrom, 0);
    atomic_init(&render->postedTo, 0);
    atomic_init(&render->draining, false);
    atomic_init(&render->gainBits, bitsOf(1.0f));
    atomic_init(&render->silenceRequest, 0);
    atomic_init(&render->silentFor, 0);
    render->appliedGain = 1.0f;
    render->discardSeen = 0;
    render->discarding = false;
    render->discardFrom = 0;
    render->discardTo = 0;
    render->refilling = false;
    render->fadeStep = render->fadeFrames;
    render->live = false;
    render->heldFrames = 0;
    render->heldPlayed = 0;
    return render;
}

void HALRenderDestroy(HALRender *render) {
    free(render->held);
    free(render);
}

uint64_t HALRenderUnderrunBytes(const HALRender *render) {
    return atomic_load_explicit(&((HALRender *)render)->underrunBytes, memory_order_relaxed);
}

uint64_t HALRenderConsumedBytes(const HALRender *render) {
    return atomic_load_explicit(&((HALRender *)render)->consumedBytes, memory_order_acquire);
}

static bool fades(const HALRender *render) { return render->samples != HALRenderSamplesOpaque; }

void HALRenderSetSilenced(HALRender *render, bool silenced) {
    uint32_t request = atomic_load_explicit(&render->silenceRequest, memory_order_relaxed);
    if (((request & 1) != 0) != silenced) {
        atomic_store_explicit(&render->silenceRequest, request + 1, memory_order_relaxed);
    }
}

bool HALRenderIsSilent(const HALRender *render) {
    HALRender *state = (HALRender *)render;
    uint32_t request = atomic_load_explicit(&state->silenceRequest, memory_order_relaxed);
    if ((request & 1) == 0) return false;
    if (!fades(render)) return true;
    // The IO proc stores the request it read at the start of the cycle that ended the fade, so
    // an older request's fade never answers for this one.
    return atomic_load_explicit(&state->silentFor, memory_order_acquire) == request;
}

void HALRenderPrepareStart(HALRender *render, bool fadesIn) {
    render->fadeStep = fadesIn ? 0 : render->fadeFrames;
    render->live = false;
    render->heldFrames = 0;
    render->heldPlayed = 0;
}

void HALRenderDiscard(HALRender *render, uint64_t fromByte, uint64_t toByte) {
    uint32_t sequence = atomic_load_explicit(&render->discardSequence, memory_order_relaxed);
    atomic_store_explicit(&render->discardSequence, sequence + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    atomic_store_explicit(&render->postedFrom, fromByte, memory_order_relaxed);
    atomic_store_explicit(&render->postedTo, toByte, memory_order_relaxed);
    // Release also orders this after the producer's writes of the bytes being skipped, so the IO
    // proc sees them as readable and skips exactly those.
    atomic_store_explicit(&render->discardSequence, sequence + 2, memory_order_release);
}

/// Moves what a fade-out from where the gain is needs of the audio before `to` into `held`,
/// unless held frames are still fading out, which carry on. With nothing queued the fade
/// starts at silence.
static void holdFadeOut(HALRender *render, uint64_t *consumed, uint64_t to) {
    if (render->heldPlayed < render->heldFrames) return;
    size_t wanted = (size_t)render->fadeStep * render->bytesPerFrame;
    size_t queued = to > *consumed ? (size_t)(to - *consumed) : 0;
    if (wanted > queued) wanted = queued - queued % render->bytesPerFrame;
    size_t copied = RingBufferRead(render->source, render->held, wanted);
    *consumed += copied;
    render->heldFrames = (uint32_t)(copied / render->bytesPerFrame);
    render->heldPlayed = 0;
    // Too little was queued to fade from where the gain is: the fade starts lower, so it still
    // reaches silence on the last held frame.
    if (render->heldFrames < render->fadeStep) render->fadeStep = render->heldFrames;
}

/// Takes up a discard the producer has posted since the last cycle. One caught mid-write is
/// picked up on the next cycle instead. One that drops what is playing skips at once, after
/// holding what its fade-out needs if the IO proc has been playing it.
static void takeDiscard(HALRender *render, uint64_t *consumed) {
    uint32_t before = atomic_load_explicit(&render->discardSequence, memory_order_acquire);
    if (before == render->discardSeen || (before & 1) != 0) return;
    uint64_t from = atomic_load_explicit(&render->postedFrom, memory_order_relaxed);
    uint64_t to = atomic_load_explicit(&render->postedTo, memory_order_relaxed);
    atomic_thread_fence(memory_order_acquire);
    if (atomic_load_explicit(&render->discardSequence, memory_order_relaxed) != before) return;
    render->discardSeen = before;
    render->discarding = true;
    render->discardFrom = from;
    render->discardTo = to;
    if (from > *consumed) return;

    // Skipping now, not when the buffer is filled, leaves no window in which a newer discard
    // replaces this one: the held frames can outlast a buffer.
    if (fades(render) && render->live) holdFadeOut(render, consumed, to);
    if (*consumed < to) *consumed += RingBufferSkip(render->source, (size_t)(to - *consumed));
    render->discarding = false;
    render->refilling = true;
}

/// Reads up to `size` bytes into `destination`, skipping the pending discard when it reaches it.
static size_t readSource(HALRender *render, uint8_t *destination, size_t size,
                         uint64_t *consumed) {
    size_t filled = 0;
    while (filled < size) {
        if (render->discarding && *consumed >= render->discardFrom) {
            if (*consumed < render->discardTo) {
                *consumed += RingBufferSkip(render->source, (size_t)(render->discardTo - *consumed));
            }
            render->discarding = false;
            render->refilling = true;
        }
        size_t wanted = size - filled;
        if (render->discarding && render->discardFrom - *consumed < wanted) {
            wanted = (size_t)(render->discardFrom - *consumed);
        }
        size_t copied = RingBufferRead(render->source, destination + filled, wanted);
        *consumed += copied;
        filled += copied;
        if (copied < wanted) break;
    }
    return filled;
}

void HALRenderSetDraining(HALRender *render, bool draining) {
    atomic_store_explicit(&render->draining, draining, memory_order_relaxed);
}

void HALRenderSetGain(HALRender *render, float gain) {
    float clamped = gain < 0.0f ? 0.0f : (gain > 1.0f ? 1.0f : gain);
    atomic_store_explicit(&render->gainBits, bitsOf(clamped), memory_order_relaxed);
}

static size_t sampleWidth(HALRenderSampleKind kind) {
    return kind == HALRenderSamplesInt16 ? 2 : (kind == HALRenderSamplesInt24 ? 3 : 4);
}

/// Scales one sample of `kind` at `sample` by `gain`.
static void scaleSample(HALRenderSampleKind kind, uint8_t *sample, double gain) {
    switch (kind) {
    case HALRenderSamplesInt16: {
        int16_t value;
        memcpy(&value, sample, 2);
        value = (int16_t)((double)value * gain);
        memcpy(sample, &value, 2);
        break;
    }
    case HALRenderSamplesInt24: {
        // Little-endian, sign-extended through the top byte.
        int32_t value = (int32_t)((uint32_t)sample[0] << 8 | (uint32_t)sample[1] << 16 |
                                  (uint32_t)sample[2] << 24) >> 8;
        value = (int32_t)((double)value * gain);
        sample[0] = (uint8_t)value;
        sample[1] = (uint8_t)(value >> 8);
        sample[2] = (uint8_t)(value >> 16);
        break;
    }
    case HALRenderSamplesInt32: {
        int32_t value;
        memcpy(&value, sample, 4);
        value = (int32_t)((double)value * gain);
        memcpy(sample, &value, 4);
        break;
    }
    case HALRenderSamplesFloat32: {
        float value;
        memcpy(&value, sample, 4);
        value = (float)((double)value * gain);
        memcpy(sample, &value, 4);
        break;
    }
    case HALRenderSamplesOpaque:
        break;
    }
}

/// Scales `bytes` of samples by a gain moving linearly from `from` to `to`.
static void applyGain(HALRenderSampleKind kind, uint8_t *bytes, size_t size, float from, float to) {
    size_t width = sampleWidth(kind);
    size_t count = size / width;
    if (count == 0) return;
    double step = ((double)to - (double)from) / (double)count;
    for (size_t i = 0; i < count; i++) {
        scaleSample(kind, bytes + i * width, (double)from + step * (double)(i + 1));
    }
}

/// Moves the fade a frame at a time toward `target` across `frames` frames at `bytes`, scaling
/// each frame by where it is. Frames at full gain are left untouched.
static void applyFade(HALRender *render, uint8_t *bytes, size_t frames, uint32_t target) {
    uint32_t step = render->fadeStep;
    uint32_t full = render->fadeFrames;
    if (step == full && target == full) return;
    size_t width = sampleWidth(render->samples);
    size_t perFrame = render->bytesPerFrame / width;
    for (size_t frame = 0; frame < frames; frame++) {
        if (step < target) {
            step++;
        } else if (step > target) {
            step--;
        }
        if (step == full) continue;
        double gain = (double)step / (double)full;
        uint8_t *first = bytes + frame * render->bytesPerFrame;
        for (size_t i = 0; i < perFrame; i++) scaleSample(render->samples, first + i * width, gain);
    }
    render->fadeStep = step;
}

OSStatus HALRenderIOProc(AudioObjectID device, const AudioTimeStamp *now,
                         const AudioBufferList *input, const AudioTimeStamp *inputTime,
                         AudioBufferList *output, const AudioTimeStamp *outputTime,
                         void *clientData) {
    (void)device, (void)now, (void)input, (void)inputTime, (void)outputTime;
    HALRender *render = clientData;
    uint64_t consumed = atomic_load_explicit(&render->consumedBytes, memory_order_relaxed);

    takeDiscard(render, &consumed);

    float gain = floatOf(atomic_load_explicit(&render->gainBits, memory_order_relaxed));
    bool draining = atomic_load_explicit(&render->draining, memory_order_relaxed);
    uint32_t request = atomic_load_explicit(&render->silenceRequest, memory_order_relaxed);
    bool silenced = (request & 1) != 0 && fades(render);

    // Stereo DACs expose one interleaved stream. Any further buffers get silence.
    for (UInt32 i = 0; i < output->mNumberBuffers; i++) {
        AudioBuffer *buffer = &output->mBuffers[i];
        uint8_t *bytes = buffer->mData;
        size_t size = buffer->mDataByteSize;
        size_t copied = 0;
        size_t heldBytes = 0;
        // A shortfall a fade to silence leaves on purpose, not an underrun.
        bool quiet = false;
        if (i == 0) {
            if (render->heldPlayed < render->heldFrames) {
                heldBytes = (size_t)(render->heldFrames - render->heldPlayed) * render->bytesPerFrame;
                if (heldBytes > size) heldBytes = size - size % render->bytesPerFrame;
                memcpy(bytes, render->held + (size_t)render->heldPlayed * render->bytesPerFrame,
                       heldBytes);
                render->heldPlayed += (uint32_t)(heldBytes / render->bytesPerFrame);
            }
            size_t wanted = size - heldBytes;
            if (render->heldPlayed < render->heldFrames) {
                wanted = 0;
            } else if (silenced) {
                // Only what the fade-out still needs after the held frames, which end at silence;
                // the rest stays queued for the play that follows.
                size_t fadeOutBytes =
                    heldBytes > 0 ? 0 : (size_t)render->fadeStep * render->bytesPerFrame;
                if (fadeOutBytes < wanted) {
                    wanted = fadeOutBytes;
                    quiet = true;
                }
            }
            copied = heldBytes + readSource(render, bytes + heldBytes, wanted, &consumed);
            // At unity the samples pass through untouched, which is what keeps output bit-perfect.
            // Opaque bytes always do.
            if (fades(render) && (gain != 1.0f || render->appliedGain != 1.0f)) {
                applyGain(render->samples, bytes, copied, render->appliedGain, gain);
            }
            render->appliedGain = gain;
            if (fades(render)) {
                size_t heldFrames = heldBytes / render->bytesPerFrame;
                applyFade(render, bytes, heldFrames, 0);
                applyFade(render, bytes + heldBytes, (copied - heldBytes) / render->bytesPerFrame,
                          silenced ? 0 : render->fadeFrames);
            }
        }
        if (copied == size) {
            // Held frames are from before the discard, so they say nothing of the refill.
            if (i == 0 && heldBytes == 0) render->refilling = false;
            continue;
        }
        memset(bytes + copied, 0, size - copied);
        if (i == 0 && !draining && !render->refilling && !quiet) {
            atomic_fetch_add_explicit(&render->underrunBytes, size - copied, memory_order_relaxed);
        }
    }
    render->live = true;
    if (silenced && render->fadeStep == 0 && render->heldPlayed == render->heldFrames) {
        atomic_store_explicit(&render->silentFor, request, memory_order_release);
    }
    atomic_store_explicit(&render->consumedBytes, consumed, memory_order_release);
    return noErr;
}
