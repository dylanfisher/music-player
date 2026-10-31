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
    _Atomic uint64_t discardBefore;
    _Atomic bool draining;
    /// The bits of a float, because C11 doesn't promise `_Atomic float` is lock-free.
    _Atomic uint32_t gainBits;
    /// IO proc only: the gain the last buffer ended at, the start of the next ramp.
    float appliedGain;
    /// IO proc only: the last discard target it acted on.
    uint64_t discardSeen;
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
    atomic_init(&render->discardBefore, 0);
    atomic_init(&render->draining, false);
    atomic_init(&render->gainBits, bitsOf(1.0f));
    render->appliedGain = 1.0f;
    render->discardSeen = 0;
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

void HALRenderDiscardBefore(HALRender *render, uint64_t producedBytes) {
    // Release orders this after the producer's writes of the bytes being discarded, so the IO proc
    // sees them as readable and skips exactly those.
    atomic_store_explicit(&render->discardBefore, producedBytes, memory_order_release);
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

    uint64_t discardBefore = atomic_load_explicit(&render->discardBefore, memory_order_acquire);
    if (discardBefore != render->discardSeen) {
        render->discardSeen = discardBefore;
        render->refilling = true;
        if (consumed < discardBefore) {
            consumed += RingBufferSkip(render->source, (size_t)(discardBefore - consumed));
        }
    }

    float gain = floatOf(atomic_load_explicit(&render->gainBits, memory_order_relaxed));
    bool draining = atomic_load_explicit(&render->draining, memory_order_relaxed);

    // Stereo DACs expose one interleaved stream. Any further buffers get silence.
    for (UInt32 i = 0; i < output->mNumberBuffers; i++) {
        AudioBuffer *buffer = &output->mBuffers[i];
        size_t size = buffer->mDataByteSize;
        size_t copied = i == 0 ? RingBufferRead(render->source, buffer->mData, size) : 0;
        if (i == 0) {
            consumed += copied;
            // At unity the samples pass through untouched, which is what keeps output bit-perfect.
            if (gain != 1.0f || render->appliedGain != 1.0f) {
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
