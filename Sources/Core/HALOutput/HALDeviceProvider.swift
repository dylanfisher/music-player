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
        return try lock.withLock {
            // A record an earlier run couldn't restore holds the state from before that run, which
            // is the one to put back.
            let records = try readRestoreRecords(restoreRecordURL)
            let snapshot =
                try self.snapshot ?? records.first { $0.deviceUID == deviceUID }
                ?? HALDevice.snapshot(of: id, uid: deviceUID)
            let device = try HALDevice(
                id: id, name: deviceName, hogMode: hogMode, restoring: snapshot)
            // Written only once the device is held, and for every session, since closing the last
            // one removed it.
            try writeRestoreRecords(adding(snapshot, to: records), to: restoreRecordURL)
            self.snapshot = snapshot
            return RestoringDevice(device, uid: deviceUID, recordURL: restoreRecordURL)
        }
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

    /// Restores each device left changed by a run that ended without restoring it, such as a
    /// crash, and returns what it did, or nil when there was nothing to do. A record file that
    /// doesn't read is deleted; a device that isn't connected, or won't take the restore, keeps its
    /// record for next time.
    public static func recoverAfterCrash(restoreRecordURL url: URL) throws -> String? {
        let records: [DeviceSnapshot]
        do {
            records = try readRestoreRecords(url)
        } catch let error as DecodingError {
            try FileManager.default.removeItem(at: url)
            return "discarded \(url.path), which didn't read: \(error)"
        }
        guard !records.isEmpty else { return nil }
        var kept: [DeviceSnapshot] = []
        var report: [String] = []
        for snapshot in records {
            let uid = snapshot.deviceUID
            guard let id = try deviceID(uid: uid) else {
                kept.append(snapshot)
                report.append(
                    "the device \(uid) that an earlier run left changed isn't connected; it will be"
                        + " restored once it is")
                continue
            }
            do {
                let device = try HALDevice(
                    id: id, name: try readString(id, address(kAudioObjectPropertyName)),
                    hogMode: false, restoring: snapshot)
                try device.close()
                report.append(
                    "restored \(uid) and the default outputs, which an earlier run left changed")
            } catch {
                kept.append(snapshot)
                report.append(
                    "couldn't restore \(uid), which an earlier run left changed: \(error). It will"
                        + " be tried again next time.")
            }
        }
        try writeRestoreRecords(kept, to: url)
        return report.joined(separator: "\n")
    }
}

/// `device-restore.json` in the app's data folder, `~/Library/Application Support/MusicPlayer`.
public func restoreRecordURL(in dataDirectory: URL) -> URL {
    dataDirectory.appendingPathComponent("device-restore.json")
}

/// The snapshots in the record file, one per device UID; none when there is no file.
func readRestoreRecords(_ url: URL) throws -> [DeviceSnapshot] {
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch CocoaError.fileReadNoSuchFile {
        return []
    }
    return try JSONDecoder().decode([DeviceSnapshot].self, from: data)
}

/// Deletes the file once nothing is left to restore.
func writeRestoreRecords(_ records: [DeviceSnapshot], to url: URL) throws {
    guard !records.isEmpty else {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        return
    }
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(records).write(to: url, options: .atomic)
}

/// `records` with `snapshot` added, unless its device already has one: a record not yet restored
/// is never overwritten, since it holds the older and truer state.
func adding(_ snapshot: DeviceSnapshot, to records: [DeviceSnapshot]) -> [DeviceSnapshot] {
    records.contains { $0.deviceUID == snapshot.deviceUID } ? records : records + [snapshot]
}

/// Removes the device's restore record once the device has been put back.
private final class RestoringDevice: PCMDevice {
    private let device: HALDevice
    private let uid: String
    private let recordURL: URL

    init(_ device: HALDevice, uid: String, recordURL: URL) {
        self.device = device
        self.uid = uid
        self.recordURL = recordURL
    }

    func configure(sampleRateHz: Double, channels: UInt32) throws -> DeviceFormat {
        try device.configure(sampleRateHz: sampleRateHz, channels: channels)
    }
    func start(_ render: OpaquePointer) throws { try device.start(render) }
    func stop() throws { try device.stop() }
    func abandon() -> Bool { device.abandon() }

    func close() throws {
        try device.close()
        let records = try readRestoreRecords(recordURL)
        try writeRestoreRecords(records.filter { $0.deviceUID != uid }, to: recordURL)
    }
}
