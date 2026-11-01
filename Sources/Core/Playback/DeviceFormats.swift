/// What a device says it can take: the HAL's available nominal rates, and its first output
/// stream's physical formats.
public struct DeviceFormats: Sendable, Equatable {
    public var sampleRatesHz: [ClosedRange<Double>]
    public var formats: [PhysicalFormat]

    public init(sampleRatesHz: [ClosedRange<Double>], formats: [PhysicalFormat]) {
        self.sampleRatesHz = sampleRatesHz
        self.formats = formats
    }

    /// Whether the device offers `sampleRateHz` and has a format that carries `channels` of
    /// samples at it unchanged. Mixability isn't asked: whether a non-mixable format may be used
    /// depends on hog mode, which opening the device settles.
    public func takes(sampleRateHz: Double, channels: UInt32) -> Bool {
        sampleRatesHz.contains { $0.contains(sampleRateHz) }
            && formats.contains { $0.carries(sampleRateHz: sampleRateHz, channels: channels) }
    }
}
