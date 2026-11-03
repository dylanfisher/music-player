#ifndef HAL_RENDER_H
#define HAL_RENDER_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#include "RingBuffer.h"

CF_ASSUME_NONNULL_BEGIN

/// State for `HALRenderIOProc`: where it reads samples from, how far it has read, and how often it
/// came up short. One producer thread writes `source` and calls the producer-side functions below;
/// the IO proc is the only reader.
typedef struct HALRender HALRender;

/// The sample layout of the device format, which the digital gain needs. All native-endian
/// interleaved PCM.
typedef enum {
    HALRenderSamplesInt16,
    /// Packed in 3 bytes.
    HALRenderSamplesInt24,
    /// Also 24-bit samples aligned high in 4 bytes.
    HALRenderSamplesInt32,
    HALRenderSamplesFloat32,
    /// Bytes the IO proc copies and never scales, whatever the gain: DoP, whose markers any
    /// change breaks.
    HALRenderSamplesOpaque,
} HALRenderSampleKind;

/// Does not take ownership of `source`, which must outlive the IO proc. The gain starts at 1, which
/// copies samples untouched. Not real-time safe.
HALRender *_Nullable HALRenderCreate(RingBuffer *source, HALRenderSampleKind samples);

/// Not real-time safe. The IO proc must have been stopped.
void HALRenderDestroy(HALRender *render);

/// Bytes of silence written because `source` was empty while the producer still had audio for it.
uint64_t HALRenderUnderrunBytes(const HALRender *render);

/// Bytes the IO proc has taken from `source` since it was created, played or discarded. The
/// producer compares this with its own count of bytes written to tell which byte is playing.
uint64_t HALRenderConsumedBytes(const HALRender *render);

/// Producer side, safe while the IO proc runs. Makes the IO proc skip the bytes from `fromByte` up
/// to `toByte` instead of playing them; both count bytes written since `source` was created, and
/// `toByte` must not be past what the producer has written. The producer writes the audio that
/// follows straight away, from `toByte` on.
///
/// With `fromByte` at or before what the IO proc has consumed, everything queued before `toByte`
/// is dropped at the start of its next cycle: a seek. With `fromByte` ahead, the IO proc plays up
/// to it and skips from there, mid-buffer if need be: replacing an already queued next track while
/// the current one finishes untouched. A newer discard replaces one the IO proc hasn't reached.
/// Shortfalls after a skip, until the IO proc next fills a whole buffer, are not underruns. Only
/// one producer may call this.
void HALRenderDiscard(HALRender *render, uint64_t fromByte, uint64_t toByte);

/// Producer side. True while the producer has nothing more to write for now, at the end of the
/// queue or before a format change, so the silence that follows is not counted as an underrun.
void HALRenderSetDraining(HALRender *render, bool draining);

/// Any thread. Linear amplitude from 0 to 1, applied from the next IO cycle with a ramp across that
/// buffer so the change doesn't click.
void HALRenderSetGain(HALRender *render, float gain);

/// A CoreAudio IO proc. `clientData` is a `HALRender *`. Copies bytes from the ring buffer into the
/// first output buffer, so the producer must write them in the device's format. Pads any shortfall
/// with silence. Never allocates, locks, or blocks. Nullability matches `AudioDeviceIOProc`, so
/// Swift accepts it as one.
OSStatus HALRenderIOProc(AudioObjectID device, const AudioTimeStamp *now,
                         const AudioBufferList *input, const AudioTimeStamp *inputTime,
                         AudioBufferList *output, const AudioTimeStamp *outputTime,
                         void *_Nullable clientData);

CF_ASSUME_NONNULL_END

#endif
