import CoreAudio

/// What a device was configured to.
public struct DeviceFormat {
    /// What the IO proc writes, interleaved.
    public var stream: AudioStreamBasicDescription
    /// For display: the device's name and hardware format, such as
    /// `ADI-2 DAC: 'lpcm' 2 ch 32-bit int @ 96 kHz, non-mixable, hog mode`.
    public var summary: String
    /// From the IO proc taking a byte to the device playing it, which a drain waits out before
    /// stopping the device.
    public var latencySeconds: Double

    public init(stream: AudioStreamBasicDescription, summary: String, latencySeconds: Double) {
        self.stream = stream
        self.summary = summary
        self.latencySeconds = latencySeconds
    }
}

/// One open session on an output device, which `DeviceOutput` configures and pulls
/// `HALRenderIOProc` through. A CoreAudio device in the app; a stand-in that runs the IO proc on
/// its own thread in tests and benchmarks. Used from one thread.
public protocol PCMDevice: AnyObject {
    /// Switches the hardware to `sampleRateHz` with `channels`, passing samples through
    /// unchanged.
    func configure(sampleRateHz: Double, channels: UInt32) throws -> DeviceFormat
    /// Starts calling `HALRenderIOProc` with `render` (a `HALRender *`).
    func start(_ render: OpaquePointer) throws
    /// Returns once the IO proc has stopped being called.
    func stop() throws
    /// Stops, and puts the device back the way it was before this run first opened it.
    func close() throws
    /// The device has gone away: stop without restoring anything.
    func abandon()
}

/// Finds and opens the one device an output plays to, and says when it comes and goes.
public protocol PCMDeviceProvider: AnyObject, Sendable {
    var deviceName: String { get }
    /// Nil when the device isn't connected.
    func open() throws -> (any PCMDevice)?
    func isConnected() -> Bool
    /// Calls `changed`, on any thread, whenever the device may have appeared or disappeared,
    /// until `stopWatching()`.
    func watch(_ changed: @escaping @Sendable () -> Void) throws
    func stopWatching()
    /// The device is back while no session holds it: put back what can be put back without
    /// opening it, such as the system's default output.
    func deviceReturned()
}
