import CoreAudio
import Testing

@testable import HALOutput
@testable import Playback

private func ranged(bits: UInt32, channels: UInt32 = 2, float: Bool = false, mixable: Bool)
    -> AudioStreamRangedDescription
{
    var flags = float ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger
    if !mixable { flags |= kAudioFormatFlagIsNonMixable }
    return AudioStreamRangedDescription(
        mFormat: AudioStreamBasicDescription(
            mSampleRate: 0, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
            mBytesPerPacket: bits / 8 * channels, mFramesPerPacket: 1,
            mBytesPerFrame: bits / 8 * channels, mChannelsPerFrame: channels,
            mBitsPerChannel: bits, mReserved: 0),
        mSampleRateRange: AudioValueRange(mMinimum: 44_100, mMaximum: 192_000))
}

/// What the ADI-2 offers: 2 ch 32-bit int, mixable and not, plus a float format for contrast.
private let available = [
    ranged(bits: 32, float: true, mixable: true), ranged(bits: 32, mixable: true),
    ranged(bits: 32, mixable: false), ranged(bits: 16, channels: 8, mixable: false),
]

@Test func hogModePicksTheNonMixableIntegerFormat() throws {
    let format = try #require(
        bitPerfectFormat(in: available, sampleRateHz: 96_000, channels: 2, allowNonMixable: true))
    #expect(format.mFormatFlags & kAudioFormatFlagIsNonMixable != 0)
    #expect(format.mBitsPerChannel == 32)
    #expect(format.mSampleRate == 96_000)
}

@Test func withoutHogModeOnlyMixableFormatsQualify() throws {
    let format = try #require(
        bitPerfectFormat(in: available, sampleRateHz: 96_000, channels: 2, allowNonMixable: false))
    #expect(format.mFormatFlags & kAudioFormatFlagIsNonMixable == 0)
    #expect(format.mFormatFlags & kAudioFormatFlagIsFloat == 0)
}

@Test func channelsAndRateMustMatch() {
    #expect(
        bitPerfectFormat(in: available, sampleRateHz: 96_000, channels: 1, allowNonMixable: true)
            == nil)
    #expect(
        bitPerfectFormat(in: available, sampleRateHz: 384_000, channels: 2, allowNonMixable: true)
            == nil)
}

@Test func dopTakesOnlyANonMixableFormatWideEnoughForItsWords() throws {
    let narrow = [ranged(bits: 16, mixable: false), ranged(bits: 32, mixable: true)]
    #expect(
        bitPerfectFormat(
            in: narrow, sampleRateHz: 176_400, channels: 2, minimumBits: 24, nonMixableOnly: true,
            allowNonMixable: true) == nil)
    let format = try #require(
        bitPerfectFormat(
            in: available, sampleRateHz: 176_400, channels: 2, minimumBits: 24,
            nonMixableOnly: true, allowNonMixable: true))
    #expect(format.mFormatFlags & kAudioFormatFlagIsNonMixable != 0)
}

private func physical(
    _ rates: ClosedRange<Double>, bits: UInt32 = 32, channels: UInt32 = 2, float: Bool = false,
    mixable: Bool = true
) -> PhysicalFormat {
    PhysicalFormat(
        formatID: linearPCMFormatID, sampleRateHz: rates, bitsPerChannel: bits,
        channels: channels, isFloat: float, isMixable: mixable)
}

@Test func airPodsTakeEveryTrackAsStereoFloatAt48kHz() throws {
    // What Bluetooth AirPods offer on macOS 12: 16 kHz mono for calls, and 48 kHz stereo.
    let airPods = [
        physical(16_000...16_000, bits: 16, channels: 1), physical(48_000...48_000, float: true),
    ]
    for rate in [8_000.0, 16_000, 22_050, 44_100, 48_000, 96_000] {
        for channels: UInt32 in [1, 2, 6] {
            let target = try #require(
                convertedFormat(
                    in: airPods, sampleRateHz: rate, channels: channels, allowNonMixable: false))
            #expect(target.index == 1)
            #expect(target.sampleRateHz == 48_000)
        }
    }
}

@Test func theNearestRateAtOrAboveTheTracksWins() throws {
    let formats = [
        physical(32_000...32_000), physical(48_000...48_000), physical(96_000...96_000),
        physical(88_200...88_200),
    ]
    func target(_ rate: Double) throws -> Double {
        try #require(
            convertedFormat(in: formats, sampleRateHz: rate, channels: 2, allowNonMixable: false)
        ).sampleRateHz
    }
    #expect(try target(44_100) == 48_000)
    #expect(try target(88_200) == 88_200)
    #expect(try target(176_400) == 96_000)
    let range = [physical(8_000...48_000)]
    #expect(
        convertedFormat(in: range, sampleRateHz: 22_050, channels: 2, allowNonMixable: false)?
            .sampleRateHz == 44_100)
    let low = [physical(8_000...32_000)]
    #expect(
        convertedFormat(in: low, sampleRateHz: 22_050, channels: 2, allowNonMixable: false)?
            .sampleRateHz == 32_000)
}

@Test func channelsMatchThenGoUpThenDown() throws {
    let formats = [physical(48_000...48_000, channels: 2), physical(48_000...48_000, channels: 8)]
    func channels(_ count: UInt32) throws -> UInt32 {
        let target = try #require(
            convertedFormat(
                in: formats, sampleRateHz: 44_100, channels: count, allowNonMixable: false))
        return formats[target.index].channels
    }
    #expect(try channels(2) == 2)
    #expect(try channels(1) == 2)
    #expect(try channels(6) == 8)
    #expect(try channels(10) == 8)
    // Channels come before the rate.
    let mono = [physical(44_100...44_100, channels: 1), physical(96_000...96_000, channels: 2)]
    #expect(
        convertedFormat(in: mono, sampleRateHz: 44_100, channels: 2, allowNonMixable: false)?
            .index == 1)
}

@Test func floatThenTheWidestWinsAndNonMixableNeedsHogMode() throws {
    let formats = [
        physical(48_000...48_000, bits: 16), physical(48_000...48_000, bits: 24, mixable: false),
        physical(48_000...48_000, bits: 32, float: true, mixable: false),
    ]
    let held = try #require(
        convertedFormat(in: formats, sampleRateHz: 44_100, channels: 2, allowNonMixable: true))
    #expect(held.index == 2)
    let shared = try #require(
        convertedFormat(in: formats, sampleRateHz: 44_100, channels: 2, allowNonMixable: false))
    #expect(shared.index == 0)
    let noPCM = [
        PhysicalFormat(
            formatID: "ac-3", sampleRateHz: 48_000...48_000, bitsPerChannel: 0, channels: 6,
            isFloat: false, isMixable: true)
    ]
    #expect(
        convertedFormat(in: noPCM, sampleRateHz: 48_000, channels: 2, allowNonMixable: true)
            == nil)
}
