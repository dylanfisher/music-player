import CoreAudio
import Foundation
import Log

private let logger = moduleLogger()

public enum HALDeviceProviderError: Error, CustomStringConvertible {
    case noDefaultOutput

    public var description: String {
        switch self {
        case .noDefaultOutput: "macOS has no default output device"
        }
    }
}

/// The CoreAudio device with one UID. It listens for the device list changing and for the device
/// dying, and never substitutes another device.
///
/// The first open in a run snapshots the device and the system's default outputs, and every later
/// session restores that snapshot, so a device that was unplugged and came back is still put back
/// the way it was before playback. The snapshot is also written to `restoreRecordURL` until a
/// session restores it, so `recoverAfterCrash` can restore it after a run that never got to.
public final class HALDeviceProvider: PCMDeviceProvider, @unchecked Sendable {
    private let deviceUID: String
    public let deviceName: String
    private let hogMode: Bool
    private let restoreRecordURL: URL
    private let queue = DispatchQueue(label: "\(bundleIdentifier).device-watch")
    private let lock = NSLock()
    private var snapshot: DeviceSnapshot?
    private var listener: AudioObjectPropertyListenerBlock?
    /// The device the `IsAlive` listener is on, which changes when it is plugged back in.
    private var aliveListenerDevice: AudioObjectID?

    /// `deviceUID` nil means the system's default output now. It is resolved once, so when that
    /// device goes away playback pauses instead of following macOS to another one.
    public init(deviceUID: String?, hogMode: Bool, restoreRecordURL: URL) throws {
        if let deviceUID {
            self.deviceUID = deviceUID
        } else {
            let id = try AudioDevice.defaultOutputID()
            guard id != kAudioObjectUnknown else { throw HALDeviceProviderError.noDefaultOutput }
            self.deviceUID = try readString(id, address(kAudioDevicePropertyDeviceUID))
        }
        let id = try deviceID(uid: self.deviceUID)
        deviceName =
            try id.map { try readString($0, address(kAudioObjectPropertyName)) } ?? self.deviceUID
        self.hogMode = hogMode
        self.restoreRecordURL = restoreRecordURL
    }

    public func open() throws -> (any PCMDevice)? {
        guard let id = try liveDeviceID() else { return nil }
        let snapshot = try lock.withLock {
            let taken = try self.snapshot ?? HALDevice.snapshot(of: id, uid: deviceUID)
            self.snapshot = taken
            return taken
        }
        // Written for every session, since closing the last one deleted it.
        try writeRestoreRecord(snapshot, to: restoreRecordURL)
        return try RestoringDevice(
            HALDevice(id: id, name: deviceName, hogMode: hogMode, restoring: snapshot),
            recordURL: restoreRecordURL)
    }

    public func isConnected() -> Bool {
        do {
            return try liveDeviceID() != nil
        } catch {
            logger.error("can't read the device list: \(error)")
            return false
        }
    }

    private func liveDeviceID() throws -> AudioObjectID? {
        guard let id = try deviceID(uid: deviceUID) else { return nil }
        let alive: UInt32 = try readScalar(id, address(kAudioDevicePropertyDeviceIsAlive))
        return alive == 0 ? nil : id
    }

    public func watch(_ changed: @escaping @Sendable () -> Void) throws {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.followDevice()
            changed()
        }
        lock.withLock { listener = block }
        var devices = address(kAudioHardwarePropertyDevices)
        try throwIfError(
            "AudioObjectAddPropertyListenerBlock(devices)",
            AudioObjectAddPropertyListenerBlock(systemObject, &devices, queue, block))
        followDevice()
    }

    /// Moves the `IsAlive` listener to the device's current object ID.
    private func followDevice() {
        lock.withLock {
            guard let listener else { return }
            let id: AudioObjectID?
            do {
                id = try deviceID(uid: deviceUID)
            } catch {
                logger.error("can't read the device list: \(error)")
                return
            }
            guard id != aliveListenerDevice else { return }
            var alive = address(kAudioDevicePropertyDeviceIsAlive)
            // The old ID belongs to a device that's gone, so removing from it can fail.
            if let old = aliveListenerDevice {
                _ = AudioObjectRemovePropertyListenerBlock(old, &alive, queue, listener)
            }
            aliveListenerDevice = nil
            guard let id else { return }
            let status = AudioObjectAddPropertyListenerBlock(id, &alive, queue, listener)
            if status == noErr {
                aliveListenerDevice = id
            } else {
                logger.error("can't watch device \(id) for removal: \(status)")
            }
        }
    }

    public func stopWatching() {
        lock.withLock {
            guard let listener else { return }
            var devices = address(kAudioHardwarePropertyDevices)
            removeListener(listener, from: systemObject, &devices)
            if let device = aliveListenerDevice {
                var alive = address(kAudioDevicePropertyDeviceIsAlive)
                removeListener(listener, from: device, &alive)
            }
            self.listener = nil
            aliveListenerDevice = nil
        }
    }

    private func removeListener(
        _ listener: @escaping AudioObjectPropertyListenerBlock, from object: AudioObjectID,
        _ address: inout AudioObjectPropertyAddress
    ) {
        let status = AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener)
        if status != noErr {
            logger.error("removing a device listener from \(object) failed: \(status)")
        }
    }

    public func deviceReturned() {
        guard let snapshot = lock.withLock({ snapshot }) else { return }
        do {
            try restoreDefaultOutputs(snapshot)
        } catch {
            logger.error("restoring the default outputs failed: \(error)")
        }
    }

    /// Restores a device left changed by a run that ended without restoring it, such as a crash,
    /// and returns what it did, or nil when there was nothing to do. A record that doesn't read
    /// is deleted; one whose device isn't connected, or won't take the restore, is kept for next
    /// time.
    public static func recoverAfterCrash(restoreRecordURL url: URL) throws -> String? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        let snapshot: DeviceSnapshot
        do {
            snapshot = try JSONDecoder().decode(DeviceSnapshot.self, from: data)
        } catch {
            try FileManager.default.removeItem(at: url)
            return "discarded \(url.path), which didn't read: \(error)"
        }
        guard let id = try deviceID(uid: snapshot.deviceUID) else {
            return "the device \(snapshot.deviceUID) that an earlier run left changed isn't"
                + " connected; it will be restored once it is"
        }
        do {
            let device = try HALDevice(
                id: id, name: try readString(id, address(kAudioObjectPropertyName)),
                hogMode: false, restoring: snapshot)
            try device.close()
        } catch {
            return "couldn't restore \(snapshot.deviceUID), which an earlier run left changed:"
                + " \(error). It will be tried again next time."
        }
        try FileManager.default.removeItem(at: url)
        return "restored \(snapshot.deviceUID) and the default outputs, which an earlier run"
            + " left changed"
    }
}

/// `~/Library/Application Support/MusicPlayer/device-restore.json`, beside the settings file.
public func defaultRestoreRecordURL(settingsFileURL: URL) -> URL {
    settingsFileURL.deletingLastPathComponent().appendingPathComponent("device-restore.json")
}

private func writeRestoreRecord(_ snapshot: DeviceSnapshot, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
}

/// Deletes the restore record once the device has been put back.
private final class RestoringDevice: PCMDevice {
    private let device: HALDevice
    private let recordURL: URL

    init(_ device: HALDevice, recordURL: URL) {
        self.device = device
        self.recordURL = recordURL
    }

    func configure(sampleRateHz: Double, channels: UInt32) throws -> DeviceFormat {
        try device.configure(sampleRateHz: sampleRateHz, channels: channels)
    }
    func start(_ render: OpaquePointer) throws { try device.start(render) }
    func stop() throws { try device.stop() }
    func abandon() { device.abandon() }

    func close() throws {
        try device.close()
        if FileManager.default.fileExists(atPath: recordURL.path) {
            try FileManager.default.removeItem(at: recordURL)
        }
    }
}
