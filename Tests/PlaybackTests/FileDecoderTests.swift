import AudioToolbox
import Foundation
import Testing

@testable import Playback

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
