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
    // No mix from 10 channels to 8.
    #expect(try channels(10) == 2)
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

private func roles(_ count: Int) -> [ChannelRole] {
    ChannelOrder(defaultFor: count, isAssumed: false).roles
}

@Test func downmixesFollowITUWithAFixedHeadroomAndStereoToMonoAverages() throws {
    #expect(try channelMix(from: roles(2), to: 1) == [0.5, 0.5])
    let minus3dB = Float(0.5.squareRoot())
    let headroom = 1 / (1 + minus3dB)
    // L R C LFE Ls Rs to stereo: the LFE is left out, and the rest is -4.6 dB below ITU.
    let left: [Float] = [1, 0, minus3dB, 0, minus3dB, 0].map { $0 * headroom }
    let right: [Float] = [0, 1, minus3dB, 0, 0, minus3dB].map { $0 * headroom }
    for (got, want) in zip(try channelMix(from: roles(6), to: 2), left + right) {
        #expect(abs(got - want) < 1e-6)
    }
    #expect(abs(headroom - 0.586) < 1e-3)
    // A mono track goes to both sides; stereo to the first two of more.
    #expect(try channelMix(from: roles(1), to: 2) == [1, 1])
    #expect(try channelMix(from: roles(2), to: 4) == [1, 0, 0, 1, 0, 0, 0, 0])
}

@Test func theRateFloorOutranksTheDepthAndChannels() throws {
    // AirPods-like: 2 ch 16-bit at 48 kHz beside a deeper 16 kHz mono call format. A 24-bit
    // track keeps its depth only in the call format, which mustn't win.
    let formats = [
        physical(48_000...48_000, bits: 16),
        physical(16_000...16_000, bits: 32, channels: 1, float: true),
    ]
    #expect(try target(formats, flac(44_100, bits: 24)).index == 0)
    #expect(try target(formats, flac(22_050, bits: 24)).index == 0)
}

@Test func aFormatNoDownmixReachesComesLast() throws {
    // 8 channels to 6 has no mix, so the 2 ch format wins though it's narrower.
    let formats = [
        physical(48_000...48_000, bits: 24, channels: 6),
        physical(48_000...48_000, bits: 16, channels: 2),
    ]
    #expect(try target(formats, flac(48_000, channels: 8, bits: 24)).index == 1)
    // Alone, it's still picked, and the converter refuses it by name.
    #expect(try target([formats[0]], flac(48_000, channels: 8, bits: 24)).index == 0)
}

@Test func aLossyTrackIsJudgedAsTheVerdictJudgesIt() throws {
    let aac = SignalFormat(
        formatID: "aac ", sampleRateHz: 44_100, bitsPerChannel: nil, channels: 6, isFloat: false)
    let int16 = physical(44_100...192_000, bits: 16, channels: 8)
    // A lossy track's precision is whatever it's decoded to, so a 16-bit format loses nothing.
    #expect(int16.holdsSamples(Precision(file: aac, decodedAs: int16.precision)))
    let verdict = signalVerdict(
        SignalPath(
            track: TrackSignal(
                file: aac,
                decoded: SignalFormat(
                    formatID: linearPCMFormatID, sampleRateHz: 44_100, bitsPerChannel: 16,
                    channels: 6, isFloat: false),
                isConverted: false, channelOrderAssumed: false),
            sink: .device(DeviceSink(name: "DAC", uid: "DAC", state: .notConnected, gain: 1))))
    #expect(verdict == .changed([.deviceNotConnected]))
    // So beside the ADI-2's 2 ch 32-bit format, its 8 ch 16-bit one keeps every channel.
    let formats = [physical(44_100...192_000, bits: 32), int16]
    #expect(try target(formats, aac).index == 1)
}
