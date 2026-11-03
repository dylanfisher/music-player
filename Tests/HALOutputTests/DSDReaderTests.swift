import CoreAudio
import Foundation
import Testing

@testable import Fixtures
@testable import HALOutput
@testable import Playback

private func integer(bits: UInt32, bytes: UInt32, alignedHigh: Bool = false, float: Bool = false)
    -> AudioStreamBasicDescription
{
    AudioStreamBasicDescription(
        mSampleRate: 176_400, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: (float ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger)
            | kAudioFormatFlagIsPacked | (alignedHigh ? kAudioFormatFlagIsAlignedHigh : 0),
        mBytesPerPacket: bytes * 2, mFramesPerPacket: 1, mBytesPerFrame: bytes * 2,
        mChannelsPerFrame: 2, mBitsPerChannel: bits, mReserved: 0)
}

/// Writes `data` as a file with `fileExtension` for the duration of the test.
private func file(_ data: Data, _ fileExtension: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("dsd-\(UUID().uuidString).\(fileExtension)", isDirectory: false)
    try data.write(to: url)
    return url
}

private func read(_ reader: DSDReader, frames: Int, bytesPerFrame: Int) throws -> [UInt8] {
    var output = [UInt8](repeating: 0xEE, count: frames * bytesPerFrame)
    let count = try output.withUnsafeMutableBytes {
        try reader.read(into: $0.baseAddress!, frames: UInt32(frames))
    }
    return Array(output.prefix(Int(count) * bytesPerFrame))
}

/// Left 0x80 0x01 0xC0, right 0x0F 0xF0 0x55, oldest bit highest: one DSD sample set first on
/// the left, and patterns whose reversal differs on the right.
private let left: [UInt8] = [0x80, 0x01, 0xC0]
private let right: [UInt8] = [0x0F, 0xF0, 0x55]

@Test(arguments: ["dsf", "dff"])
func theOldestBitGoesHighestUnderAlternatingMarkers(fileExtension: String) throws {
    let channels = [Data(left), Data(right)]
    let data =
        fileExtension == "dsf"
        ? dsfFile(rateHz: 2_822_400, channels: channels)
        : dffFile(rateHz: 2_822_400, channels: channels)
    let reader = try DSDReader(url: try file(data, fileExtension))
    #expect(reader.carrierRateHz == 176_400)
    // Three bytes make one frame and a half; the half is padded with idle, and the pair with a
    // frame of DoP silence.
    #expect(reader.lengthFrames == 2)
    try reader.setOutputFormat(integer(bits: 32, bytes: 4))
    // Little-endian 32-bit: zero, the newer byte, the older byte, the marker.
    #expect(
        try read(reader, frames: 4, bytesPerFrame: 8) == [
            0, 0x01, 0x80, 0x05, 0, 0xF0, 0x0F, 0x05,
            0, 0x69, 0xC0, 0xFA, 0, 0x69, 0x55, 0xFA,
        ])
    #expect(try read(reader, frames: 2, bytesPerFrame: 8).isEmpty)
    try reader.seek(toFrame: 1)
    #expect(reader.nextFrame == 0)
    try reader.setOutputFormat(integer(bits: 24, bytes: 3))
    #expect(
        try read(reader, frames: 2, bytesPerFrame: 6) == [
            0x01, 0x80, 0x05, 0xF0, 0x0F, 0x05, 0x69, 0xC0, 0xFA, 0x69, 0x55, 0xFA,
        ])
}

@Test func aFormatThatCantCarryDoPIsRefused() throws {
    let reader = try DSDReader(
        url: try file(dsfFile(rateHz: 2_822_400, channels: [Data(left), Data(right)]), "dsf"))
    try reader.setOutputFormat(integer(bits: 24, bytes: 4, alignedHigh: true))
    for format in [
        integer(bits: 16, bytes: 2), integer(bits: 32, bytes: 4, float: true),
        integer(bits: 24, bytes: 4),
    ] {
        #expect(throws: DeviceOutputError.self) { try reader.setOutputFormat(format) }
    }
}

@Test func aDSFsBlocksAreReadAcrossTheirEdges() throws {
    // Two blocks and a bit per channel, so reads cross block groups.
    let channels = (0..<2).map { channel in
        Data((0..<9000).map { UInt8(truncatingIfNeeded: $0 * 7 + channel * 101) })
    }
    let reader = try DSDReader(url: try file(dsfFile(rateHz: 2_822_400, channels: channels), "dsf"))
    try reader.setOutputFormat(integer(bits: 24, bytes: 3))
    try reader.seek(toFrame: 2046)
    let bytes = try read(reader, frames: 6, bytesPerFrame: 6)
    for frame in 0..<6 {
        for channel in 0..<2 {
            let word = Array(bytes[(frame * 2 + channel) * 3..<(frame * 2 + channel) * 3 + 3])
            let k = (2046 + frame) * 2
            #expect(
                word == [channels[channel][k + 1], channels[channel][k], dopMarkers[frame & 1]])
        }
    }
}

@Test func theRefusalSaysWhatTheDeviceLacks() {
    #expect(
        "\(DeviceOutputError.cannotPlayDSD(device: "ADI-2", dsdRateHz: 5_644_800, carrierRateHz: 352_800, hasRate: false))"
            == "ADI-2 can't play DSD128: it has no 352.8 kHz rate for DoP")
    #expect(
        "\(DeviceOutputError.cannotPlayDSD(device: "Speakers", dsdRateHz: 2_822_400, carrierRateHz: 176_400, hasRate: true))"
            == "Speakers can't play DSD64: it has no 24-bit integer format at 176.4 kHz for DoP")
}
