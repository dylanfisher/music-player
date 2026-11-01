import Playback

/// A device to play on, and the settings its profile gives it.
public struct DeviceChoice: Sendable {
    public var provider: any PCMDeviceProvider
    /// Turns on `setVolume`. Until it is used, samples still pass untouched.
    public var digitalVolume: Bool
    /// The digital volume to start at, as a linear amplitude. Unused without `digitalVolume`.
    public var gain: Double
    /// What the device reported when it was last seen, so a track it can't take is refused
    /// before it reports again. Nil for a device never seen.
    public var formats: DeviceFormats?

    public init(
        provider: any PCMDeviceProvider, digitalVolume: Bool, gain: Double, formats: DeviceFormats?
    ) {
        self.provider = provider
        self.digitalVolume = digitalVolume
        self.gain = gain
        self.formats = formats
    }
}
