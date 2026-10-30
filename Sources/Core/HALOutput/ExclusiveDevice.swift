import CoreAudio
import Foundation
import HALRender

public enum ExclusiveDeviceError: Error, CustomStringConvertible {
    case hogModeHeld(by: pid_t)
    case noOutputStream
    case noBitPerfectFormat(sampleRateHz: Double)
    case didNotSettle(String)
    case outOfMemory

    public var description: String {
        switch self {
        case .hogModeHeld(let pid):
            "another process (pid \(pid)) has exclusive access to the device"
        case .noOutputStream: "the device has no output stream"
        case .noBitPerfectFormat(let rate):
            "the device has no integer format at \(kilohertz(rate)) kHz"
        case .didNotSettle(let what): "the device didn't switch to \(what) within 3 seconds"
        case .outOfMemory: "couldn't allocate the render state"
        }
    }
}

/// An output device held in hog mode and switched to a bit-perfect format, then put back as it
/// was by `close()`. Use from one thread.
public final class ExclusiveDevice {
    public let id: AudioObjectID
    private let stream: AudioStreamID
    private let originalRateHz: Double
    private let originalFormat: AudioStreamBasicDescription
    private let originalDefaults: [(selector: AudioObjectPropertySelector, device: AudioObjectID)]
    private var ioProc: AudioDeviceIOProcID?
    private var render: OpaquePointer?
    private var isOpen = true

    /// Takes hog mode, so no other process can play to or reconfigure the device.
    public init(id: AudioObjectID) throws {
        let streams: [AudioStreamID] = try readArray(
            id, address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput))
        guard let stream = streams.first else { throw ExclusiveDeviceError.noOutputStream }
        let owner: pid_t = try readScalar(id, address(kAudioDevicePropertyHogMode))
        guard owner == -1 || owner == getpid() else {
            throw ExclusiveDeviceError.hogModeHeld(by: owner)
        }

        self.id = id
        self.stream = stream
        originalRateHz = try readScalar(id, address(kAudioDevicePropertyNominalSampleRate))
        originalFormat = try readScalar(stream, address(kAudioStreamPropertyPhysicalFormat))
        originalDefaults = try defaultOutputSelectors.map { selector in
            (selector, try readScalar(systemObject, address(selector)))
        }

        try writeScalar(id, address(kAudioDevicePropertyHogMode), getpid())
        let newOwner: pid_t = try readScalar(id, address(kAudioDevicePropertyHogMode))
        guard newOwner == getpid() else { throw ExclusiveDeviceError.hogModeHeld(by: newOwner) }
    }

    /// Switches the hardware to `sampleRateHz` in its bit-perfect format, and returns the format
    /// the IO proc has to write.
    public func configure(sampleRateHz: Double) throws -> AudioStreamBasicDescription {
        let available: [AudioStreamRangedDescription] = try readArray(
            stream, address(kAudioStreamPropertyAvailablePhysicalFormats))
        guard let format = bitPerfectFormat(in: available, sampleRateHz: sampleRateHz) else {
            throw ExclusiveDeviceError.noBitPerfectFormat(sampleRateHz: sampleRateHz)
        }

        // Rate first: on some devices setting the physical format alone leaves the clock where
        // it was.
        try writeScalar(id, address(kAudioDevicePropertyNominalSampleRate), sampleRateHz)
        try waitUntil("\(kilohertz(sampleRateHz)) kHz") {
            try readScalar(id, address(kAudioDevicePropertyNominalSampleRate)) == sampleRateHz
        }
        try writeScalar(stream, address(kAudioStreamPropertyPhysicalFormat), format)
        try waitUntil(PhysicalFormat(format).summary) {
            let now: AudioStreamBasicDescription = try readScalar(
                stream, address(kAudioStreamPropertyPhysicalFormat))
            return PhysicalFormat(now) == PhysicalFormat(format)
        }
        return try readScalar(stream, address(kAudioStreamPropertyVirtualFormat))
    }

    /// The hardware format right now.
    public func physicalFormat() throws -> PhysicalFormat {
        let format: AudioStreamBasicDescription = try readScalar(
            stream, address(kAudioStreamPropertyPhysicalFormat))
        return PhysicalFormat(format)
    }

    /// Starts the IO proc, which plays bytes from `source` (a `RingBuffer *`) as they are. The
    /// ring buffer must outlive `stop()`.
    public func start(reading source: OpaquePointer) throws {
        guard let render = HALRenderCreate(source) else { throw ExclusiveDeviceError.outOfMemory }
        self.render = render
        var procID: AudioDeviceIOProcID?
        try throwIfError(
            "AudioDeviceCreateIOProcID",
            AudioDeviceCreateIOProcID(id, HALRenderIOProc, UnsafeMutableRawPointer(render), &procID)
        )
        ioProc = procID
        try throwIfError("AudioDeviceStart", AudioDeviceStart(id, procID))
    }

    /// Bytes of silence played because the ring buffer ran dry.
    public var underrunBytes: UInt64 { render.map { HALRenderUnderrunBytes($0) } ?? 0 }

    public func stop() throws {
        if let ioProc {
            try throwIfError("AudioDeviceStop", AudioDeviceStop(id, ioProc))
            try throwIfError("AudioDeviceDestroyIOProcID", AudioDeviceDestroyIOProcID(id, ioProc))
            self.ioProc = nil
        }
        if let render {
            HALRenderDestroy(render)
            self.render = nil
        }
    }

    /// Stops playback, restores the rate and format the device had before, releases hog mode, and
    /// restores the system's default output devices.
    public func close() throws {
        guard isOpen else { return }
        isOpen = false
        try stop()
        try writeScalar(stream, address(kAudioStreamPropertyPhysicalFormat), originalFormat)
        try writeScalar(id, address(kAudioDevicePropertyNominalSampleRate), originalRateHz)
        try writeScalar(id, address(kAudioDevicePropertyHogMode), pid_t(-1))
        // While a device is hogged, macOS moves the default output and alert-sound output to
        // another device, and doesn't move them back when hog mode ends.
        for original in originalDefaults {
            let now: AudioObjectID = try readScalar(systemObject, address(original.selector))
            if now != original.device {
                try writeScalar(systemObject, address(original.selector), original.device)
            }
        }
    }
}

private let systemObject = AudioObjectID(kAudioObjectSystemObject)

/// System Settings → Sound → Output, and the device for alerts and sound effects.
private let defaultOutputSelectors = [
    kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice,
]

/// Polls until `condition` holds. Devices apply rate and format changes asynchronously, and
/// playing before they finish produces a click or the wrong rate.
private func waitUntil(_ what: String, _ condition: () throws -> Bool) throws {
    let deadline = Date().addingTimeInterval(3)
    while try !condition() {
        guard Date() < deadline else { throw ExclusiveDeviceError.didNotSettle(what) }
        Thread.sleep(forTimeInterval: 0.01)
    }
}
