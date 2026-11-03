#include "HALRender.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// Fields marked "IO proc only" are touched by whichever thread runs the IO proc. CoreAudio starts
// and stops it with a happens-before edge, so they need no atomics.
struct HALRender {
    RingBuffer *source;
    HALRenderSampleKind samples;
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

HALRender *HALRenderCreate(RingBuffer *source, HALRenderSampleKind samples) {
    HALRender *render = malloc(sizeof *render);
    if (render == NULL) return NULL;
    render->source = source;
    render->samples = samples;
    atomic_init(&render->underrunBytes, 0);
    atomic_init(&render->consumedBytes, 0);
    atomic_init(&render->discardSequence, 0);
    atomic_init(&render->postedFrom, 0);
    atomic_init(&render->postedTo, 0);
    atomic_init(&render->draining, false);
    atomic_init(&render->gainBits, bitsOf(1.0f));
    render->appliedGain = 1.0f;
    render->discardSeen = 0;
    render->discarding = false;
    render->discardFrom = 0;
    render->discardTo = 0;
    render->refilling = false;
    return render;
}

void HALRenderDestroy(HALRender *render) { free(render); }

uint64_t HALRenderUnderrunBytes(const HALRender *render) {
    return atomic_load_explicit(&((HALRender *)render)->underrunBytes, memory_order_relaxed);
}

uint64_t HALRenderConsumedBytes(const HALRender *render) {
    return atomic_load_explicit(&((HALRender *)render)->consumedBytes, memory_order_acquire);
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

/// Takes up a discard the producer has posted since the last cycle. One caught mid-write is
/// picked up on the next cycle instead.
static void takeDiscard(HALRender *render) {
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

/// Scales `bytes` of samples by a gain moving linearly from `from` to `to`.
static void applyGain(HALRenderSampleKind kind, uint8_t *bytes, size_t size, float from, float to) {
    size_t width = kind == HALRenderSamplesInt16 ? 2 : (kind == HALRenderSamplesInt24 ? 3 : 4);
    size_t count = size / width;
    if (count == 0) return;
    double step = ((double)to - (double)from) / (double)count;
    for (size_t i = 0; i < count; i++) {
        double gain = (double)from + step * (double)(i + 1);
        uint8_t *sample = bytes + i * width;
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
            return;
        }
    }
}

OSStatus HALRenderIOProc(AudioObjectID device, const AudioTimeStamp *now,
                         const AudioBufferList *input, const AudioTimeStamp *inputTime,
                         AudioBufferList *output, const AudioTimeStamp *outputTime,
                         void *clientData) {
    (void)device, (void)now, (void)input, (void)inputTime, (void)outputTime;
    HALRender *render = clientData;
    uint64_t consumed = atomic_load_explicit(&render->consumedBytes, memory_order_relaxed);

    takeDiscard(render);

    float gain = floatOf(atomic_load_explicit(&render->gainBits, memory_order_relaxed));
    bool draining = atomic_load_explicit(&render->draining, memory_order_relaxed);

    // Stereo DACs expose one interleaved stream. Any further buffers get silence.
    for (UInt32 i = 0; i < output->mNumberBuffers; i++) {
        AudioBuffer *buffer = &output->mBuffers[i];
        size_t size = buffer->mDataByteSize;
        size_t copied = i == 0 ? readSource(render, buffer->mData, size, &consumed) : 0;
        if (i == 0) {
            // At unity the samples pass through untouched, which is what keeps output bit-perfect.
            // Opaque bytes always do.
            if (render->samples != HALRenderSamplesOpaque &&
                (gain != 1.0f || render->appliedGain != 1.0f)) {
                applyGain(render->samples, buffer->mData, copied, render->appliedGain, gain);
            }
            render->appliedGain = gain;
        }
        if (copied == size) {
            if (i == 0) render->refilling = false;
            continue;
        }
        memset((uint8_t *)buffer->mData + copied, 0, size - copied);
        if (i == 0 && !draining && !render->refilling) {
            atomic_fetch_add_explicit(&render->underrunBytes, size - copied, memory_order_relaxed);
        }
    }
    atomic_store_explicit(&render->consumedBytes, consumed, memory_order_release);
    return noErr;
}
