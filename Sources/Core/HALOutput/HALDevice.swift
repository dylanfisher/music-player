import CoreAudio
import DisplayText
import Foundation
import HALRender
import Log
import Playback

private let logger = moduleLogger()

enum HALDeviceError: PlaybackFailure {
    case hogModeHeld(by: pid_t)
    case noOutputStream
    case noBitPerfectFormat(sampleRateHz: Double, channels: UInt32, minimumBits: UInt32)
    /// Nothing to convert a track to: no PCM format, or only non-mixable ones without hog mode.
    case noPCMFormat
    case didNotSettle(String)

    var description: String {
        switch self {
        case .hogModeHeld(let pid):
            "another process (pid \(pid)) has exclusive access to the device"
        case .noOutputStream: "the device has no output stream"
        case .noBitPerfectFormat(let rate, let channels, let bits):
            "the device has no \(bits > 0 ? "non-mixable " : "")\(channels)-channel integer format"
                + (bits > 0 ? " of \(bits) bits or more" : "") + " at \(kilohertz(rate)) kHz"
        case .noPCMFormat: "the device has no PCM format this app can convert to"
        case .didNotSettle(let what): "the device didn't switch to \(what) within 3 seconds"
        }
    }

    var userMessage: String {
        switch self {
        case .hogModeHeld: "another app has the device to itself"
        case .noOutputStream: "the device has no output"
        case .noBitPerfectFormat(let rate, let channels, _):
            "the device can't play \(channels) channels at \(kilohertz(rate)) kHz unchanged"
        case .noPCMFormat: "the device has no format the app can play to"
        case .didNotSettle: "the device didn't switch to the track's format in time"
        }
    }
}

/// A CoreAudio output device switched to a bit-perfect format, or a converted one when it has
/// none (ADR 0071), optionally in hog mode so no other
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

    func configure(sampleRateHz: Double, channels: UInt32, forDoP: Bool, file: SignalFormat)
        throws -> DeviceFormat
    {
        let minimumBits = forDoP ? dopWordBits : 0
        let available: [AudioStreamRangedDescription] = try readArray(
            stream, address(kAudioStreamPropertyAvailablePhysicalFormats))
        let format: AudioStreamBasicDescription
        let isConverted: Bool
        if let unchanged = bitPerfectFormat(
            in: available, sampleRateHz: sampleRateHz, channels: channels,
            minimumBits: minimumBits, nonMixableOnly: forDoP, allowNonMixable: hogMode)
        {
            (format, isConverted) = (unchanged, false)
        } else if !forDoP,
            let target = convertedFormat(
                in: available.map(PhysicalFormat.init), for: file, allowNonMixable: hogMode)
        {
            var converted = available[target.index].mFormat
            converted.mSampleRate = target.sampleRateHz
            (format, isConverted) = (converted, true)
        } else if forDoP {
            throw HALDeviceError.noBitPerfectFormat(
                sampleRateHz: sampleRateHz, channels: channels, minimumBits: minimumBits)
        } else {
            throw HALDeviceError.noPCMFormat
        }
        let rateHz = format.mSampleRate

        let clock = StepClock()
        // Rate first: on some devices setting the physical format alone leaves the clock where
        // it was.
        try clock.time("rate") {
            try writeScalar(id, address(kAudioDevicePropertyNominalSampleRate), rateHz)
            try waitUntil(
                "\(kilohertz(rateHz)) kHz", id, address(kAudioDevicePropertyNominalSampleRate)
            ) {
                try readScalar(id, address(kAudioDevicePropertyNominalSampleRate)) == rateHz
            }
        }
        try clock.time("format") {
            try writeScalar(stream, address(kAudioStreamPropertyPhysicalFormat), format)
            try waitUntil(
                PhysicalFormat(format).summary, stream,
                address(kAudioStreamPropertyPhysicalFormat)
            ) {
                let now: AudioStreamBasicDescription = try readScalar(
                    stream, address(kAudioStreamPropertyPhysicalFormat))
                return PhysicalFormat(now) == PhysicalFormat(format)
            }
        }
        let current: AudioStreamBasicDescription = try readScalar(
            stream, address(kAudioStreamPropertyPhysicalFormat))
        let physical = PhysicalFormat(current)
        let switched = physical.summary + (isConverted ? ", converting the track to it" : "")
        logger.info(
            "device \(self.id, privacy: .public): switched to \(switched, privacy: .public)")
        return DeviceFormat(
            stream: try readScalar(stream, address(kAudioStreamPropertyVirtualFormat)),
            summary: "\(name): \(physical.summary)\(hogMode ? ", hog mode" : "")",
            shown: "\(name): \(physical.shown)",
            latencySeconds: try latencyFrames() / rateHz, isConverted: isConverted,
            steps: clock.steps)
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
    /// the system's default output devices. Returns once the device reads as restored, or throws
    /// after 3 seconds.
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
            // The HAL applies these writes asynchronously. A session opened before they land,
            // as a settings change opens one straight after, would configure a device that is
            // still changing under it.
            { try self.waitForRestoredFormat() },
            {
                if self.hogMode {
                    try writeScalar(self.id, address(kAudioDevicePropertyHogMode), pid_t(-1))
                    try waitUntil(
                        "hog mode released", self.id, address(kAudioDevicePropertyHogMode)
                    ) {
                        let owner: pid_t = try readScalar(
                            self.id, address(kAudioDevicePropertyHogMode))
                        return owner != getpid()
                    }
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

    private func waitForRestoredFormat() throws {
        let format = PhysicalFormat(snapshot.physicalFormat.basicDescription)
        try waitUntil(
            "\(kilohertz(snapshot.sampleRateHz)) kHz, \(format.summary)", stream,
            address(kAudioStreamPropertyPhysicalFormat)
        ) {
            let rate: Double = try readScalar(id, address(kAudioDevicePropertyNominalSampleRate))
            let now: AudioStreamBasicDescription = try readScalar(
                stream, address(kAudioStreamPropertyPhysicalFormat))
            return rate == snapshot.sampleRateHz && PhysicalFormat(now) == format
        }
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

/// Waits until `condition` holds, for up to 3 seconds. Devices apply rate and format changes
/// asynchronously, and playing before they finish produces a click or the wrong rate. A listener on
/// `property` wakes the check as soon as the device reports a change, instead of up to one poll
/// interval later; it still rechecks every 50 ms in case a notification never comes.
private func waitUntil(
    _ what: String, _ object: AudioObjectID, _ property: AudioObjectPropertyAddress,
    _ condition: () throws -> Bool
) throws {
    if try condition() { return }
    let changed = DispatchSemaphore(value: 0)
    let listener: AudioObjectPropertyListenerBlock = { _, _ in changed.signal() }
    let queue = DispatchQueue.global(qos: .userInteractive)
    var address = property
    try throwIfError(
        "AudioObjectAddPropertyListenerBlock",
        AudioObjectAddPropertyListenerBlock(object, &address, queue, listener))
    defer {
        let status = AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener)
        if status != noErr { logger.error("removing the \(what) listener failed: \(status)") }
    }
    let deadline = Date().addingTimeInterval(3)
    while try !condition() {
        guard Date() < deadline else { throw HALDeviceError.didNotSettle(what) }
        _ = changed.wait(timeout: .now() + 0.05)
    }
}
