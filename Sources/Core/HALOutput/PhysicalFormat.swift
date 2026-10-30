import CoreAudio

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
