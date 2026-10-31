#include "RingBuffer.h"

#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// `head` and `tail` count bytes ever written and read, and are masked only to index `bytes`.
// Unsigned wraparound keeps `head - tail` correct after they overflow.
struct RingBuffer {
    _Atomic size_t head;
    _Atomic size_t tail;
    size_t mask;
    uint8_t *bytes;
};

RingBuffer *RingBufferCreate(size_t capacity) {
    if (capacity == 0 || capacity > SIZE_MAX / 2 + 1) return NULL;
    size_t rounded = 1;
    while (rounded < capacity) rounded <<= 1;

    RingBuffer *buffer = malloc(sizeof *buffer);
    if (buffer == NULL) return NULL;
    buffer->bytes = malloc(rounded);
    if (buffer->bytes == NULL) {
        free(buffer);
        return NULL;
    }
    atomic_init(&buffer->head, 0);
    atomic_init(&buffer->tail, 0);
    buffer->mask = rounded - 1;
    return buffer;
}

void RingBufferDestroy(RingBuffer *buffer) {
    if (buffer == NULL) return;
    free(buffer->bytes);
    free(buffer);
}

size_t RingBufferCapacity(const RingBuffer *buffer) { return buffer->mask + 1; }

size_t RingBufferWrite(RingBuffer *buffer, const void *source, size_t count) {
    size_t head = atomic_load_explicit(&buffer->head, memory_order_relaxed);
    // Acquire pairs with the consumer's release, so the bytes it read are free to overwrite.
    size_t tail = atomic_load_explicit(&buffer->tail, memory_order_acquire);
    size_t space = RingBufferCapacity(buffer) - (head - tail);
    size_t n = count < space ? count : space;

    size_t start = head & buffer->mask;
    size_t first = n < RingBufferCapacity(buffer) - start ? n : RingBufferCapacity(buffer) - start;
    memcpy(buffer->bytes + start, source, first);
    memcpy(buffer->bytes, (const uint8_t *)source + first, n - first);

    atomic_store_explicit(&buffer->head, head + n, memory_order_release);
    return n;
}

size_t RingBufferRead(RingBuffer *buffer, void *destination, size_t count) {
    size_t tail = atomic_load_explicit(&buffer->tail, memory_order_relaxed);
    // Acquire pairs with the producer's release, so the bytes it wrote are visible.
    size_t head = atomic_load_explicit(&buffer->head, memory_order_acquire);
    size_t available = head - tail;
    size_t n = count < available ? count : available;

    size_t start = tail & buffer->mask;
    size_t first = n < RingBufferCapacity(buffer) - start ? n : RingBufferCapacity(buffer) - start;
    memcpy(destination, buffer->bytes + start, first);
    memcpy((uint8_t *)destination + first, buffer->bytes, n - first);

    atomic_store_explicit(&buffer->tail, tail + n, memory_order_release);
    return n;
}

size_t RingBufferSkip(RingBuffer *buffer, size_t count) {
    size_t tail = atomic_load_explicit(&buffer->tail, memory_order_relaxed);
    size_t head = atomic_load_explicit(&buffer->head, memory_order_acquire);
    size_t available = head - tail;
    size_t n = count < available ? count : available;
    atomic_store_explicit(&buffer->tail, tail + n, memory_order_release);
    return n;
}

size_t RingBufferReadable(const RingBuffer *buffer) {
    size_t head = atomic_load_explicit(&((RingBuffer *)buffer)->head, memory_order_acquire);
    size_t tail = atomic_load_explicit(&((RingBuffer *)buffer)->tail, memory_order_relaxed);
    return head - tail;
}
