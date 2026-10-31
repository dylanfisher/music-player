import CoreAudio
import Foundation
import HALRender
import Log

private let logger = moduleLogger()

public enum HALDeviceError: Error, CustomStringConvertible {
    case hogModeHeld(by: pid_t)
    case noOutputStream
    case noBitPerfectFormat(sampleRateHz: Double, channels: UInt32)
    case didNotSettle(String)

    public var description: String {
        switch self {
        case .hogModeHeld(let pid):
            "another process (pid \(pid)) has exclusive access to the device"
        case .noOutputStream: "the device has no output stream"
        case .noBitPerfectFormat(let rate, let channels):
            "the device has no \(channels)-channel integer format at \(kilohertz(rate)) kHz"
        case .didNotSettle(let what): "the device didn't switch to \(what) within 3 seconds"
        }
    }
}

/// A CoreAudio output device switched to a bit-perfect format, optionally in hog mode so no other
/// process can play through it or reconfigure it. `close()` puts back the snapshot taken before
/// this run first changed it.
final class HALDevice: PCMDevice {
    let id: AudioObjectID
    private let name: String
    private let stream: AudioStreamID
    private let hogMode: Bool
    private let snapshot: DeviceSnapshot
    private var ioProc: AudioDeviceIOProcID?
    private var isOpen = true

    /// With `hogMode`, takes exclusive access first.
    init(id: AudioObjectID, name: String, hogMode: Bool, restoring snapshot: DeviceSnapshot) throws
    {
        let streams: [AudioStreamID] = try readArray(
            id, address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput))
        guard let stream = streams.first else { throw HALDeviceError.noOutputStream }
        let owner: pid_t = try readScalar(id, address(kAudioDevicePropertyHogMode))
        guard owner == -1 || owner == getpid() else { throw HALDeviceError.hogModeHeld(by: owner) }

        self.id = id
        self.name = name
        self.stream = stream
        self.hogMode = hogMode
        self.snapshot = snapshot
        guard hogMode else { return }
        try writeScalar(id, address(kAudioDevicePropertyHogMode), getpid())
        let newOwner: pid_t = try readScalar(id, address(kAudioDevicePropertyHogMode))
        guard newOwner == getpid() else { throw HALDeviceError.hogModeHeld(by: newOwner) }
        logger.info("device \(id, privacy: .public): took hog mode")
    }

    /// The device and the system's default outputs as they are now.
    static func snapshot(of id: AudioObjectID, uid: String) throws -> DeviceSnapshot {
        let streams: [AudioStreamID] = try readArray(
            id, address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput))
        guard let stream = streams.first else { throw HALDeviceError.noOutputStream }
        let format: AudioStreamBasicDescription = try readScalar(
            stream, address(kAudioStreamPropertyPhysicalFormat))
        func defaultUID(_ selector: AudioObjectPropertySelector) throws -> String? {
            let device: AudioObjectID = try readScalar(systemObject, address(selector))
            return device == kAudioObjectUnknown
                ? nil : try readString(device, address(kAudioDevicePropertyDeviceUID))
        }
        return DeviceSnapshot(
            deviceUID: uid,
            sampleRateHz: try readScalar(id, address(kAudioDevicePropertyNominalSampleRate)),
            physicalFormat: StoredFormat(format),
            defaultOutputUID: try defaultUID(kAudioHardwarePropertyDefaultOutputDevice),
            defaultSystemOutputUID: try defaultUID(kAudioHardwarePropertyDefaultSystemOutputDevice))
    }

    func configure(sampleRateHz: Double, channels: UInt32) throws -> DeviceFormat {
        let available: [AudioStreamRangedDescription] = try readArray(
            stream, address(kAudioStreamPropertyAvailablePhysicalFormats))
        guard
            let format = bitPerfectFormat(
                in: available, sampleRateHz: sampleRateHz, channels: channels,
                allowNonMixable: hogMode)
        else {
            throw HALDeviceError.noBitPerfectFormat(sampleRateHz: sampleRateHz, channels: channels)
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
        let current: AudioStreamBasicDescription = try readScalar(
            stream, address(kAudioStreamPropertyPhysicalFormat))
        let physical = PhysicalFormat(current)
        logger.info(
            "device \(self.id, privacy: .public): switched to \(physical.summary, privacy: .public)"
        )
        return DeviceFormat(
            stream: try readScalar(stream, address(kAudioStreamPropertyVirtualFormat)),
            summary: "\(name): \(physical.summary)\(hogMode ? ", hog mode" : "")",
            latencySeconds: try latencyFrames() / sampleRateHz)
    }

    /// The IO buffer plus everything the HAL and the device add after it.
    private func latencyFrames() throws -> Double {
        let output = kAudioObjectPropertyScopeOutput
        let frames: [UInt32] = [
            try readScalar(id, address(kAudioDevicePropertyBufferFrameSize)),
            try readScalar(id, address(kAudioDevicePropertyLatency, scope: output)),
            try readScalar(id, address(kAudioDevicePropertySafetyOffset, scope: output)),
            try readScalar(stream, address(kAudioStreamPropertyLatency)),
        ]
        return Double(frames.reduce(0, +))
    }

    func start(_ render: OpaquePointer) throws {
        var procID: AudioDeviceIOProcID?
        try throwIfError(
            "AudioDeviceCreateIOProcID",
            AudioDeviceCreateIOProcID(id, HALRenderIOProc, UnsafeMutableRawPointer(render), &procID)
        )
        ioProc = procID
        try throwIfError("AudioDeviceStart", AudioDeviceStart(id, procID))
    }

    func stop() throws {
        guard let ioProc else { return }
        self.ioProc = nil
        try throwIfError("AudioDeviceStop", AudioDeviceStop(id, ioProc))
        try throwIfError("AudioDeviceDestroyIOProcID", AudioDeviceDestroyIOProcID(id, ioProc))
    }

    /// Stops playback, restores the snapshot's rate and format, releases hog mode, and restores
    /// the system's default output devices.
    func close() throws {
        guard isOpen else { return }
        isOpen = false
        // Every step runs even when an earlier one fails, so one failure doesn't leave hog mode
        // held or the default output moved.
        let steps: [() throws -> Void] = [
            { try self.stop() },
            {
                try writeScalar(
                    self.stream, address(kAudioStreamPropertyPhysicalFormat),
                    self.snapshot.physicalFormat.basicDescription)
            },
            {
                try writeScalar(
                    self.id, address(kAudioDevicePropertyNominalSampleRate),
                    self.snapshot.sampleRateHz)
            },
            {
                if self.hogMode {
                    try writeScalar(self.id, address(kAudioDevicePropertyHogMode), pid_t(-1))
                }
            },
            { try restoreDefaultOutputs(self.snapshot) },
        ]
        var errors: [any Error] = []
        for step in steps {
            do {
                try step()
            } catch {
                logger.error("device \(self.id, privacy: .public): restoring failed: \(error)")
                errors.append(error)
            }
        }
        if let first = errors.first { throw first }
        logger.info("device \(self.id, privacy: .public): restored")
    }

    func abandon() -> Bool {
        guard isOpen else { return true }
        isOpen = false
        do {
            try stop()
            return true
        } catch {
            logger.error("device \(self.id, privacy: .public) gone, stopping it failed: \(error)")
            return false
        }
    }
}

let systemObject = AudioObjectID(kAudioObjectSystemObject)

/// While a device is hogged, macOS moves the default output and alert-sound output to another
/// device, and doesn't move them back when hog mode ends. Puts back each one whose original device
/// is connected; one that isn't is logged and left, since there is nothing to move it to.
func restoreDefaultOutputs(_ snapshot: DeviceSnapshot) throws {
    for (selector, uid) in [
        (kAudioHardwarePropertyDefaultOutputDevice, snapshot.defaultOutputUID),
        (kAudioHardwarePropertyDefaultSystemOutputDevice, snapshot.defaultSystemOutputUID),
    ] {
        guard let uid else { continue }
        guard let original = try deviceID(uid: uid) else {
            logger.error("can't restore default output \(uid): it isn't connected")
            continue
        }
        let now: AudioObjectID = try readScalar(systemObject, address(selector))
        if now != original { try writeScalar(systemObject, address(selector), original) }
    }
}

/// The connected device with this UID, or nil.
func deviceID(uid: String) throws -> AudioObjectID? {
    let ids: [AudioObjectID] = try readArray(systemObject, address(kAudioHardwarePropertyDevices))
    return try ids.first { try readString($0, address(kAudioDevicePropertyDeviceUID)) == uid }
}

/// Polls until `condition` holds. Devices apply rate and format changes asynchronously, and
/// playing before they finish produces a click or the wrong rate.
private func waitUntil(_ what: String, _ condition: () throws -> Bool) throws {
    let deadline = Date().addingTimeInterval(3)
    while try !condition() {
        guard Date() < deadline else { throw HALDeviceError.didNotSettle(what) }
        Thread.sleep(forTimeInterval: 0.01)
    }
}
