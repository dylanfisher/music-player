#ifndef HAL_RENDER_H
#define HAL_RENDER_H

#include <CoreAudio/CoreAudio.h>
#include <stdint.h>

#include "RingBuffer.h"

CF_ASSUME_NONNULL_BEGIN

/// State for `HALRenderIOProc`: where it reads samples from, and how often it came up short.
typedef struct HALRender HALRender;

/// Does not take ownership of `source`, which must outlive the IO proc. Not real-time safe.
HALRender *_Nullable HALRenderCreate(RingBuffer *source);

/// Not real-time safe. The IO proc must have been stopped.
void HALRenderDestroy(HALRender *render);

/// Bytes of silence written because `source` was empty.
uint64_t HALRenderUnderrunBytes(const HALRender *render);

/// A CoreAudio IO proc. `clientData` is a `HALRender *`. Copies bytes from the ring buffer into the
/// first output buffer as-is, so the producer must write them in the device's format. Pads any
/// shortfall with silence and counts it. Never allocates, locks, or blocks. Nullability matches
/// `AudioDeviceIOProc`, so Swift accepts it as one.
OSStatus HALRenderIOProc(AudioObjectID device, const AudioTimeStamp *now,
                         const AudioBufferList *input, const AudioTimeStamp *inputTime,
                         AudioBufferList *output, const AudioTimeStamp *outputTime,
                         void *_Nullable clientData);

CF_ASSUME_NONNULL_END

#endif
