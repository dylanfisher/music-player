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

private func flac(_ rate: Double, channels: UInt32 = 2, bits: UInt32 = 16) -> SignalFormat {
    SignalFormat(
        formatID: "flac", sampleRateHz: rate, bitsPerChannel: bits, channels: channels,
        isFloat: false)
}

private func target(_ formats: [PhysicalFormat], _ track: SignalFormat, hog: Bool = false)
    throws -> (index: Int, sampleRateHz: Double)
{
    try #require(convertedFormat(in: formats, for: track, allowNonMixable: hog))
}

@Test func airPodsTakeEveryTrackAsStereoFloatAt48kHz() throws {
    // What Bluetooth AirPods offer on macOS 12: 16 kHz mono for calls, and 48 kHz stereo.
    let airPods = [
        physical(16_000...16_000, bits: 16, channels: 1), physical(48_000...48_000, float: true),
    ]
    for rate in [8_000.0, 16_000, 22_050, 44_100, 48_000, 96_000] {
        for channels: UInt32 in [1, 2, 6] {
            let chosen = try target(airPods, flac(rate, channels: channels, bits: 24))
            #expect(chosen.index == 1)
            #expect(chosen.sampleRateHz == 48_000)
        }
    }
}

@Test func theNearestRateAtOrAboveTheTracksWins() throws {
    let formats = [
        physical(32_000...32_000), physical(48_000...48_000), physical(96_000...96_000),
        physical(88_200...88_200),
    ]
    #expect(try target(formats, flac(44_100)).sampleRateHz == 48_000)
    #expect(try target(formats, flac(88_200)).sampleRateHz == 88_200)
    #expect(try target(formats, flac(176_400)).sampleRateHz == 96_000)
    #expect(try target([physical(8_000...48_000)], flac(22_050)).sampleRateHz == 44_100)
    #expect(try target([physical(8_000...32_000)], flac(22_050)).sampleRateHz == 32_000)
}

@Test func theFewestChannelsThatLoseNothingWin() throws {
    let formats = [
        physical(48_000...48_000, channels: 2), physical(48_000...48_000, channels: 8),
        physical(48_000...48_000, channels: 6),
    ]
    func channels(_ count: UInt32) throws -> UInt32 {
        formats[try target(formats, flac(44_100, channels: count)).index].channels
    }
    #expect(try channels(2) == 2)
    #expect(try channels(1) == 2)
    #expect(try channels(6) == 6)
    #expect(try channels(7) == 8)
    #expect(try channels(10) == 8)
    // Channels come before the rate.
    let mono = [physical(44_100...44_100, channels: 1), physical(96_000...96_000, channels: 2)]
    #expect(try target(mono, flac(44_100)).index == 1)
}

@Test func theDepthComesBeforeExtraChannels() throws {
    // The ADI-2's 2 ch 32-bit integer format, beside an 8 ch 16-bit one.
    let formats = [
        physical(44_100...192_000, bits: 32), physical(44_100...192_000, bits: 16, channels: 8),
    ]
    // A 24-bit 5.1 track keeps its depth and is downmixed; a 16-bit one keeps its channels.
    #expect(try target(formats, flac(44_100, channels: 6, bits: 24)).index == 0)
    #expect(try target(formats, flac(44_100, channels: 6, bits: 16)).index == 1)
}

@Test func floatThenTheWidestWinsAndNonMixableNeedsHogMode() throws {
    let formats = [
        physical(48_000...48_000, bits: 16), physical(48_000...48_000, bits: 24, mixable: false),
        physical(48_000...48_000, bits: 32, float: true, mixable: false),
    ]
    #expect(try target(formats, flac(44_100), hog: true).index == 2)
    #expect(try target(formats, flac(44_100)).index == 0)
    let noPCM = [
        PhysicalFormat(
            formatID: "ac-3", sampleRateHz: 48_000...48_000, bitsPerChannel: 0, channels: 6,
            isFloat: false, isMixable: true)
    ]
    #expect(convertedFormat(in: noPCM, for: flac(48_000), allowNonMixable: true) == nil)
}

@Test func downmixesFollowITUAndStereoToMonoAverages() {
    #expect(channelMix(from: 2, to: 1) == [0.5, 0.5])
    let minus3dB = Float(0.5.squareRoot())
    let side = 1 + 2 * minus3dB
    // L R C LFE Ls Rs to stereo: the LFE is left out, and each side sums to 1.
    let left: [Float] = [1 / side, 0, minus3dB / side, 0, minus3dB / side, 0]
    let right: [Float] = [0, 1 / side, minus3dB / side, 0, 0, minus3dB / side]
    for (got, want) in zip(channelMix(from: 6, to: 2), left + right) {
        #expect(abs(got - want) < 1e-6)
    }
    // A mono track goes to both sides; stereo to the first two of more.
    #expect(channelMix(from: 1, to: 2) == [1, 1])
    #expect(channelMix(from: 2, to: 4) == [1, 0, 0, 1, 0, 0, 0, 0])
}
