#ifndef RING_BUFFER_H
#define RING_BUFFER_H

#include <stddef.h>

/// Lock-free single-producer, single-consumer byte queue.
///
/// Read and write never allocate, lock, or block, so the consumer side is safe to call from a
/// CoreAudio IO proc. Exactly one thread may write and exactly one thread may read.
typedef struct RingBuffer RingBuffer;

/// Allocates a buffer holding at least `capacity` bytes, rounded up to a power of two.
/// Returns NULL if `capacity` is 0 or allocation fails. Not real-time safe.
RingBuffer *RingBufferCreate(size_t capacity);

/// Not real-time safe. Both sides must have stopped using the buffer.
void RingBufferDestroy(RingBuffer *buffer);

size_t RingBufferCapacity(const RingBuffer *buffer);

/// Producer side. Copies up to `count` bytes and returns how many were copied.
size_t RingBufferWrite(RingBuffer *buffer, const void *source, size_t count);

/// Consumer side. Copies up to `count` bytes and returns how many were copied.
size_t RingBufferRead(RingBuffer *buffer, void *destination, size_t count);

/// Bytes the consumer can read now. Exact when called from the consumer thread.
size_t RingBufferReadable(const RingBuffer *buffer);

#endif
