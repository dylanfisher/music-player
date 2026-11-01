import CoreAudio
import DisplayText
import Playback

extension PhysicalFormat {
    /// A format at one fixed rate, such as a stream's current one.
    public init(_ format: AudioStreamBasicDescription) {
        self.init(
            AudioStreamRangedDescription(
                mFormat: format,
                mSampleRateRange: AudioValueRange(
                    mMinimum: format.mSampleRate, mMaximum: format.mSampleRate)))
    }

    public init(_ ranged: AudioStreamRangedDescription) {
        let format = ranged.mFormat
        self.init(
            formatID: fourCharCode(format.mFormatID),
            sampleRateHz: ranged.mSampleRateRange.mMinimum...ranged.mSampleRateRange.mMaximum,
            bitsPerChannel: format.mBitsPerChannel,
            channels: format.mChannelsPerFrame,
            isFloat: format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            isMixable: format.mFormatFlags & kAudioFormatFlagIsNonMixable == 0
        )
    }

    /// For example `'lpcm' 2 ch 32-bit int @ 96 kHz, non-mixable`.
    public var summary: String {
        let sample = sampleType(bits: bitsPerChannel, isFloat: isFloat)
        let mixing = isMixable ? "" : ", non-mixable"
        return "'\(formatID)' \(channels) ch \(sample) @ \(kilohertz(sampleRateHz)) kHz\(mixing)"
    }
}
