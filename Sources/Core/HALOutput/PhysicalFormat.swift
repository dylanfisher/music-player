import CoreAudio
import DisplayText

/// A format an output stream can run the hardware in, as opposed to the virtual format the HAL
/// mixes in. Bit-perfect playback means choosing one of these to match the track.
public struct PhysicalFormat: Sendable, Equatable {
    public var formatID: String
    public var sampleRateHz: ClosedRange<Double>
    public var bitsPerChannel: UInt32
    public var channels: UInt32
    public var isFloat: Bool
    /// False for formats the HAL can't mix other apps into; these generally need hog mode.
    public var isMixable: Bool

    public init(
        formatID: String, sampleRateHz: ClosedRange<Double>, bitsPerChannel: UInt32,
        channels: UInt32, isFloat: Bool, isMixable: Bool
    ) {
        self.formatID = formatID
        self.sampleRateHz = sampleRateHz
        self.bitsPerChannel = bitsPerChannel
        self.channels = channels
        self.isFloat = isFloat
        self.isMixable = isMixable
    }

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
}

extension PhysicalFormat {
    /// For example `'lpcm' 2 ch 32-bit int @ 96 kHz, non-mixable`.
    public var summary: String {
        let sample = sampleType(bits: bitsPerChannel, isFloat: isFloat)
        let mixing = isMixable ? "" : ", non-mixable"
        return "'\(formatID)' \(channels) ch \(sample) @ \(kilohertz(sampleRateHz)) kHz\(mixing)"
    }
}
