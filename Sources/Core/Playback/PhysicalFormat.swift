/// The four-character code of uncompressed PCM, as `SignalFormat` and `PhysicalFormat` spell it.
public let linearPCMFormatID = "lpcm"

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
}

extension PhysicalFormat {
    /// Whether this format passes `channels` of samples at `sampleRateHz` through unchanged: integer
    /// PCM, since a float format means the HAL converts.
    public func carries(sampleRateHz: Double, channels: UInt32) -> Bool {
        formatID == linearPCMFormatID && !isFloat && self.channels == channels
            && self.sampleRateHz.contains(sampleRateHz)
    }
}
