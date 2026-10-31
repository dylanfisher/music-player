import CoreAudio
import Testing

@testable import HALOutput

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
