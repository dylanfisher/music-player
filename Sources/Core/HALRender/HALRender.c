#include "HALRender.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct HALRender {
    RingBuffer *source;
    _Atomic uint64_t underrunBytes;
};

HALRender *HALRenderCreate(RingBuffer *source) {
    HALRender *render = malloc(sizeof *render);
    if (render == NULL) return NULL;
    render->source = source;
    atomic_init(&render->underrunBytes, 0);
    return render;
}

void HALRenderDestroy(HALRender *render) { free(render); }

uint64_t HALRenderUnderrunBytes(const HALRender *render) {
    return atomic_load_explicit(&((HALRender *)render)->underrunBytes, memory_order_relaxed);
}

OSStatus HALRenderIOProc(AudioObjectID device, const AudioTimeStamp *now,
                         const AudioBufferList *input, const AudioTimeStamp *inputTime,
                         AudioBufferList *output, const AudioTimeStamp *outputTime,
                         void *clientData) {
    (void)device, (void)now, (void)input, (void)inputTime, (void)outputTime;
    HALRender *render = clientData;

    // Stereo DACs expose one interleaved stream. Any further buffers get silence.
    for (UInt32 i = 0; i < output->mNumberBuffers; i++) {
        AudioBuffer *buffer = &output->mBuffers[i];
        size_t size = buffer->mDataByteSize;
        size_t copied = i == 0 ? RingBufferRead(render->source, buffer->mData, size) : 0;
        if (copied == size) continue;
        memset((uint8_t *)buffer->mData + copied, 0, size - copied);
        if (i == 0) {
            atomic_fetch_add_explicit(&render->underrunBytes, size - copied, memory_order_relaxed);
        }
    }
    return noErr;
}
