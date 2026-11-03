import AudioToolbox
import Foundation
import Testing

@testable import Fixtures
@testable import HALOutput

/// 24-bit stereo samples, including both extremes and the values either side of zero.
private let samples: [Int32] = [0x7F_FFFF, -0x80_0000, 1, -1, 0, 0x12_3456, -0x65_4321, 0x40_0000]

private func pcm(bits: UInt32, rate: Double) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: bits / 8 * 2, mFramesPerPacket: 1, mBytesPerFrame: bits / 8 * 2,
        mChannelsPerFrame: 2, mBitsPerChannel: bits, mReserved: 0)
}

/// Writes `samples` as raw little-endian 24-bit WAV, without going through a converter, so the
/// decode side is the only conversion under test.
private func writeWAV(to url: URL) throws {
    var format = pcm(bits: 24, rate: 96_000)
    var file: AudioFileID?
    #expect(
        AudioFileCreateWithURL(url as CFURL, kAudioFileWAVEType, &format, .eraseFile, &file)
            == noErr)
    var bytes = samples.flatMap { sample in
        [0, 8, 16].map { UInt8(truncatingIfNeeded: sample >> $0) }
    }
    var count = UInt32(bytes.count)
    #expect(AudioFileWriteBytes(file!, false, 0, &count, &bytes) == noErr)
    #expect(AudioFileClose(file!) == noErr)
}

@Test func decodes24BitIntoThe32BitDeviceFormatBitExact() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("decoder-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try writeWAV(to: url)

    let decoder = try FileDecoder(url: url)
    #expect(decoder.fileFormat.mSampleRate == 96_000)
    try decoder.setOutputFormat(pcm(bits: 32, rate: 96_000))

    var output = [Int32](repeating: 0, count: samples.count)
    let frames = try output.withUnsafeMutableBytes { bytes in
        try decoder.read(into: bytes.baseAddress!, frames: UInt32(samples.count / 2))
    }

    #expect(frames == UInt32(samples.count / 2))
    // Bit-perfect means the 24-bit value lands in the top 24 bits with zeros below it.
    #expect(output == samples.map { $0 << 8 })
}

/// The first frame `decoder` hands on as 32-bit integers, as fractions of full scale.
private func firstLevels(_ decoder: FileDecoder) throws -> [Double] {
    let channels = Int(decoder.fileFormat.mChannelsPerFrame)
    let bytes = UInt32(4 * channels)
    try decoder.setOutputFormat(
        AudioStreamBasicDescription(
            mSampleRate: decoder.fileFormat.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytes, mFramesPerPacket: 1, mBytesPerFrame: bytes,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0))
    var output = [Int32](repeating: 0, count: 64 * channels)
    let frames = try output.withUnsafeMutableBytes { bytes in
        try decoder.read(into: bytes.baseAddress!, frames: 64)
    }
    try #require(frames == 64)
    return output.prefix(channels).map { Double($0) / Double(1 << 31) }
}

@Test func anALACFivePointOneFileIsReadInTheWAVOrderBitExact() throws {
    // ALAC stores C L R Ls Rs LFE; ExtAudioFile hands them on as L R C LFE Ls Rs.
    let levels = (0..<6).map(levelOf)
    let url = try levelTrack(
        named: "alac-6ch.m4a", levels: levels,
        afconvert: ["-f", "m4af", "-d", "alac", "-l", "MPEG_5_1_A", "-l", "MPEG_5_1_D"],
        in: try defaultPlaybackFixturesDirectory())
    let decoder = try FileDecoder(url: url)
    #expect(
        decoder.channelOrder
            == ChannelOrder(roles: [.left, .right, .centre, .lfe, .leftSurround, .rightSurround]))
    let quantised = levels.map { ($0 * Double(1 << 23)).rounded() / Double(1 << 23) }
    #expect(try firstLevels(decoder) == quantised)
}

@Test func aWAVChannelMaskNamesItsChannels() throws {
    // A mask of L R C Cs, where the default order for four channels is L R Ls Rs.
    let url = try levelTrack(
        named: "wav-4ch-centre-surround.wav", levels: (0..<4).map(levelOf),
        afconvert: ["-f", "WAVE", "-d", "LEI24", "-l", "MPEG_4_0_A"],
        in: try defaultPlaybackFixturesDirectory())
    let decoder = try FileDecoder(url: url)
    #expect(decoder.channelOrder == ChannelOrder(roles: [.left, .right, .centre, .backCentre]))
}

@Test func aMultichannelWAVWithoutAMaskIsTakenInTheDefaultOrder() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("decoder-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try Fixtures.writeWAV(at: url, sampleRateHz: 44_100, bitsPerSample: 24, channels: 6, frames: 64)
    { _, channel in Int32(channel) }
    let decoder = try FileDecoder(url: url)
    #expect(decoder.channelOrder == ChannelOrder(defaultFor: 6, isAssumed: true))
    #expect(decoder.channelOrder.isAssumed)
}

/// A CAF of three channels holding 0.1, 0.2 and 0.3 as stored, with `layout` as its layout.
private func threeChannelCAF(_ layout: UnsafePointer<AudioChannelLayout>) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("decoder-\(UUID().uuidString).caf")
    var format = AudioStreamBasicDescription(
        mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 12, mFramesPerPacket: 1, mBytesPerFrame: 12, mChannelsPerFrame: 3,
        mBitsPerChannel: 32, mReserved: 0)
    var file: ExtAudioFileRef?
    try #require(
        ExtAudioFileCreateWithURL(
            url as CFURL, kAudioFileCAFType, &format, layout, AudioFileFlags.eraseFile.rawValue,
            &file) == noErr)
    var samples = (0..<64).flatMap { _ in [0.1, 0.2, 0.3].map { Int32($0 * Double(1 << 31)) } }
    let written = samples.withUnsafeMutableBytes { bytes in
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 3, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
        return ExtAudioFileWrite(file!, 64, &list)
    }
    try #require(written == noErr)
    try #require(ExtAudioFileDispose(file!) == noErr)
    return url
}

@Test func aLayoutOfChannelDescriptionsIsReadInTheWAVOrder() throws {
    // Only the first description fits in the struct, so the labels go in after the header.
    let layout = UnsafeMutableRawPointer.allocate(byteCount: 128, alignment: 8)
    defer { layout.deallocate() }
    layout.initializeMemory(as: UInt8.self, repeating: 0, count: 128)
    let header = layout.assumingMemoryBound(to: AudioChannelLayout.self)
    header.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
    header.pointee.mNumberChannelDescriptions = 3
    let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
    let descriptions = (layout + offset).assumingMemoryBound(to: AudioChannelDescription.self)
    // Stored C L R.
    for (index, label) in [
        kAudioChannelLabel_Center, kAudioChannelLabel_Left, kAudioChannelLabel_Right,
    ].enumerated() {
        descriptions[index].mChannelLabel = label
    }
    let url = try threeChannelCAF(header)
    defer { try? FileManager.default.removeItem(at: url) }
    let decoder = try FileDecoder(url: url)
    #expect(decoder.channelOrder == ChannelOrder(roles: [.left, .right, .centre]))
    let levels = try firstLevels(decoder)
    #expect(zip(levels, [0.2, 0.3, 0.1]).allSatisfy { abs($0 - $1) < 1e-6 })
}

@Test func aLayoutBitmapIsReadInTheWAVOrder() throws {
    var layout = AudioChannelLayout()
    layout.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelBitmap
    layout.mChannelBitmap = [.bit_Left, .bit_Right, .bit_CenterSurround]
    let url = try withUnsafePointer(to: layout) { try threeChannelCAF($0) }
    defer { try? FileManager.default.removeItem(at: url) }
    let decoder = try FileDecoder(url: url)
    #expect(decoder.channelOrder == ChannelOrder(roles: [.left, .right, .backCentre]))
}

/// Every frame `decoder` hands on as 32-bit integers.
private func allSamples(_ decoder: FileDecoder) throws -> [Int32] {
    try decoder.setOutputFormat(pcm(bits: 32, rate: decoder.fileFormat.mSampleRate))
    var samples = [Int32](repeating: 0, count: Int(decoder.lengthFrames) * 2)
    var frames = 0
    try samples.withUnsafeMutableBytes { bytes in
        while true {
            let read = try decoder.read(
                into: bytes.baseAddress! + frames * 8,
                frames: UInt32(Int(decoder.lengthFrames) - frames))
            if read == 0 { break }
            frames += Int(read)
        }
    }
    return Array(samples.prefix(frames * 2))
}

@Test func aFileReadWithLatencyDecodesTheSameAfterWaiting() throws {
    let url = try rampAlbum(
        sampleRateHz: 44_100, bitsPerSample: 16, in: try defaultPlaybackFixturesDirectory()
    ).tracks[1]
    let latency = FileLatency(openSeconds: 0.1, readSeconds: 0.002)
    let start = Date()
    let slow = try FileDecoder(url: url, latency: latency)
    #expect(Date().timeIntervalSince(start) >= latency.openSeconds)
    #expect(slow.lengthFrames == (try FileDecoder(url: url).lengthFrames))
    #expect(try allSamples(slow) == (try allSamples(FileDecoder(url: url))))
}
