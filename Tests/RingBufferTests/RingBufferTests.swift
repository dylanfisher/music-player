import RingBuffer
import Testing

@Test func roundsCapacityUpToPowerOfTwo() throws {
    let buffer = try #require(RingBufferCreate(100))
    defer { RingBufferDestroy(buffer) }
    #expect(RingBufferCapacity(buffer) == 128)
}

@Test func rejectsZeroCapacity() {
    #expect(RingBufferCreate(0) == nil)
}

@Test func writeStopsWhenFull() throws {
    let buffer = try #require(RingBufferCreate(8))
    defer { RingBufferDestroy(buffer) }
    let source = [UInt8](1...12)
    #expect(RingBufferWrite(buffer, source, 12) == 8)
    #expect(RingBufferReadable(buffer) == 8)
}

@Test func readsBackAcrossTheWrapPoint() throws {
    let buffer = try #require(RingBufferCreate(8))
    defer { RingBufferDestroy(buffer) }
    var sink = [UInt8](repeating: 0, count: 8)

    // Advance both indices to 6 so the next write of 5 bytes splits 2 + 3 around the end.
    #expect(RingBufferWrite(buffer, [UInt8](repeating: 0, count: 6), 6) == 6)
    #expect(RingBufferRead(buffer, &sink, 6) == 6)

    let source: [UInt8] = [1, 2, 3, 4, 5]
    #expect(RingBufferWrite(buffer, source, 5) == 5)
    #expect(RingBufferRead(buffer, &sink, 8) == 5)
    #expect(Array(sink.prefix(5)) == source)
    #expect(RingBufferReadable(buffer) == 0)
}
