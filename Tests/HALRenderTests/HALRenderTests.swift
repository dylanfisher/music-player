import CoreAudio
import HALRender
import RingBuffer
import Testing

/// Runs one IO cycle into an 8-byte output buffer and returns what the device would receive.
private func render(from source: OpaquePointer, _ render: OpaquePointer) -> [UInt8] {
    var output = [UInt8](repeating: 0xAA, count: 8)
    var time = AudioTimeStamp()
    var input = AudioBufferList()
    output.withUnsafeMutableBytes { bytes in
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 8, mData: bytes.baseAddress))
        let status = HALRenderIOProc(
            0, &time, &input, &time, &list, &time, UnsafeMutableRawPointer(render))
        #expect(status == noErr)
    }
    return output
}

@Test func copiesSourceBytesUnchanged() throws {
    let source = try #require(RingBufferCreate(64))
    defer { RingBufferDestroy(source) }
    let state = try #require(HALRenderCreate(source))
    defer { HALRenderDestroy(state) }

    let samples: [UInt8] = [1, 2, 3, 4, 0xFF, 0xFE, 0x80, 0x7F]
    #expect(RingBufferWrite(source, samples, 8) == 8)

    #expect(render(from: source, state) == samples)
    #expect(HALRenderUnderrunBytes(state) == 0)
}

@Test func padsShortfallWithSilenceAndCountsIt() throws {
    let source = try #require(RingBufferCreate(64))
    defer { RingBufferDestroy(source) }
    let state = try #require(HALRenderCreate(source))
    defer { HALRenderDestroy(state) }

    #expect(RingBufferWrite(source, [UInt8](repeating: 9, count: 3), 3) == 3)

    #expect(render(from: source, state) == [9, 9, 9, 0, 0, 0, 0, 0])
    #expect(HALRenderUnderrunBytes(state) == 5)
}
