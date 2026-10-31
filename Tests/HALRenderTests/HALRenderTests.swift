import CoreAudio
import HALRender
import RingBuffer
import Testing

/// Runs one IO cycle into a `count`-byte output buffer and returns what the device would receive.
private func render(_ render: OpaquePointer, bytes count: Int = 8) -> [UInt8] {
    var output = [UInt8](repeating: 0xAA, count: count)
    var time = AudioTimeStamp()
    var input = AudioBufferList()
    output.withUnsafeMutableBytes { bytes in
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: UInt32(count), mData: bytes.baseAddress))
        let status = HALRenderIOProc(
            0, &time, &input, &time, &list, &time, UnsafeMutableRawPointer(render))
        #expect(status == noErr)
    }
    return output
}

/// A ring buffer and render state that live for one test.
private final class Fixture {
    let source: OpaquePointer
    let state: OpaquePointer

    init(samples: HALRenderSampleKind = HALRenderSamplesInt32) throws {
        source = try #require(RingBufferCreate(64))
        state = try #require(HALRenderCreate(source, samples))
    }

    deinit {
        HALRenderDestroy(state)
        RingBufferDestroy(source)
    }

    func write(_ bytes: [UInt8]) {
        #expect(RingBufferWrite(source, bytes, bytes.count) == bytes.count)
    }
}

@Test func copiesSourceBytesUnchanged() throws {
    let fixture = try Fixture()
    let samples: [UInt8] = [1, 2, 3, 4, 0xFF, 0xFE, 0x80, 0x7F]
    fixture.write(samples)

    #expect(render(fixture.state) == samples)
    #expect(HALRenderUnderrunBytes(fixture.state) == 0)
    #expect(HALRenderConsumedBytes(fixture.state) == 8)
}

@Test func padsShortfallWithSilenceAndCountsIt() throws {
    let fixture = try Fixture()
    fixture.write([UInt8](repeating: 9, count: 3))

    #expect(render(fixture.state) == [9, 9, 9, 0, 0, 0, 0, 0])
    #expect(HALRenderUnderrunBytes(fixture.state) == 5)
    #expect(HALRenderConsumedBytes(fixture.state) == 3)
}

@Test func drainingSilenceIsNotAnUnderrun() throws {
    let fixture = try Fixture()
    fixture.write([UInt8](repeating: 9, count: 3))
    HALRenderSetDraining(fixture.state, true)

    #expect(render(fixture.state) == [9, 9, 9, 0, 0, 0, 0, 0])
    #expect(HALRenderUnderrunBytes(fixture.state) == 0)

    HALRenderSetDraining(fixture.state, false)
    _ = render(fixture.state)
    #expect(HALRenderUnderrunBytes(fixture.state) == 8)
}

@Test func discardSkipsOnlyWhatWasWrittenBeforeIt() throws {
    let fixture = try Fixture()
    fixture.write([1, 1, 1, 1, 1, 1])
    #expect(render(fixture.state, bytes: 2) == [1, 1])

    // Seek: drop the 4 old bytes still queued; the new audio is written straight after.
    HALRenderDiscard(fixture.state, 0, 6)
    fixture.write([2, 2, 2, 2])

    #expect(render(fixture.state, bytes: 4) == [2, 2, 2, 2])
    #expect(HALRenderConsumedBytes(fixture.state) == 10)
    #expect(HALRenderUnderrunBytes(fixture.state) == 0)
}

@Test func aDiscardAheadPlaysUpToItThenSkipsMidBuffer() throws {
    let fixture = try Fixture()
    // The current track's tail (1-4) and an old next track (5-8) are queued.
    fixture.write([1, 2, 3, 4, 5, 6, 7, 8])
    #expect(render(fixture.state, bytes: 2) == [1, 2])

    // Replace the next track: drop bytes 4..<8 and queue its replacement after them.
    HALRenderDiscard(fixture.state, 4, 8)
    fixture.write([9, 10, 11, 12])
    #expect(render(fixture.state, bytes: 6) == [3, 4, 9, 10, 11, 12])
    #expect(HALRenderConsumedBytes(fixture.state) == 12)
    #expect(HALRenderUnderrunBytes(fixture.state) == 0)
}

@Test func aNewerDiscardReplacesOneNotYetReached() throws {
    let fixture = try Fixture()
    fixture.write([1, 2, 3, 4, 5, 6])
    HALRenderDiscard(fixture.state, 4, 6)
    // A seek before the IO proc reaches byte 4 drops everything instead.
    HALRenderDiscard(fixture.state, 0, 6)
    fixture.write([7, 8])
    #expect(render(fixture.state, bytes: 2) == [7, 8])
}

@Test func refillAfterADiscardIsNotAnUnderrunUntilABufferIsFull() throws {
    let fixture = try Fixture()
    fixture.write([1, 1, 1, 1])
    HALRenderDiscard(fixture.state, 0, 4)

    #expect(render(fixture.state) == [0, 0, 0, 0, 0, 0, 0, 0])
    fixture.write([2, 2, 2, 2, 2, 2, 2, 2])
    #expect(render(fixture.state) == [2, 2, 2, 2, 2, 2, 2, 2])
    #expect(HALRenderUnderrunBytes(fixture.state) == 0)

    _ = render(fixture.state)
    #expect(HALRenderUnderrunBytes(fixture.state) == 8)
}

private func bytes<T>(_ values: [T]) -> [UInt8] {
    values.withUnsafeBytes { Array($0) }
}

private func values<T>(_ bytes: [UInt8], as: T.Type) -> [T] {
    bytes.withUnsafeBytes { Array($0.bindMemory(to: T.self)) }
}

@Test func gainRampsAcrossOneBufferThenHolds() throws {
    let fixture = try Fixture(samples: HALRenderSamplesInt32)
    HALRenderSetGain(fixture.state, 0.5)
    fixture.write(bytes([Int32](repeating: 1000, count: 4)))
    fixture.write(bytes([Int32](repeating: 1000, count: 4)))

    #expect(values(render(fixture.state, bytes: 16), as: Int32.self) == [875, 750, 625, 500])
    #expect(values(render(fixture.state, bytes: 16), as: Int32.self) == [500, 500, 500, 500])
}

@Test func gainScalesEverySampleKind() throws {
    let int16 = try Fixture(samples: HALRenderSamplesInt16)
    HALRenderSetGain(int16.state, 0.5)
    _ = render(int16.state)  // the ramp
    int16.write(bytes([Int16](arrayLiteral: 1000, -1000, 32767, -32768)))
    #expect(values(render(int16.state), as: Int16.self) == [500, -500, 16383, -16384])

    let int24 = try Fixture(samples: HALRenderSamplesInt24)
    HALRenderSetGain(int24.state, 0.5)
    _ = render(int24.state, bytes: 6)
    // 1000 and -1000 as packed little-endian 24-bit.
    int24.write([0xE8, 0x03, 0x00, 0x18, 0xFC, 0xFF])
    #expect(render(int24.state, bytes: 6) == [0xF4, 0x01, 0x00, 0x0C, 0xFE, 0xFF])

    let float = try Fixture(samples: HALRenderSamplesFloat32)
    HALRenderSetGain(float.state, 0.25)
    _ = render(float.state)
    float.write(bytes([Float](arrayLiteral: 1, -0.5)))
    #expect(values(render(float.state), as: Float.self) == [0.25, -0.125])
}

@Test func unityGainAfterAChangeIsBitExactAgain() throws {
    let fixture = try Fixture(samples: HALRenderSamplesInt32)
    HALRenderSetGain(fixture.state, 0.5)
    _ = render(fixture.state)
    HALRenderSetGain(fixture.state, 1)
    _ = render(fixture.state)  // ramps back up

    let samples: [Int32] = [Int32.max, Int32.min]
    fixture.write(bytes(samples))
    #expect(values(render(fixture.state), as: Int32.self) == samples)
}
