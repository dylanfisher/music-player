import CoreAudio
import Foundation
import Log
import Playback

private let logger = moduleLogger()

enum HALDeviceProviderError: Error, CustomStringConvertible {
    case noDefaultOutput

    var description: String {
        switch self {
        case .noDefaultOutput: "macOS has no default output device"
        }
    }
}

/// The CoreAudio device with one UID. It listens for the device list changing and for the device
/// dying, and never substitutes another device. It also follows the properties that decide
/// whether the device plays samples unchanged, and reports its state each time one changes.
///
/// The first open in a run snapshots the device and the system's default outputs into
/// `snapshots`, which every provider for the device shares, and every later session restores
/// that snapshot, so a device that was unplugged and came back is still put back the way it was
/// before playback. The snapshot is also written to `restoreRecordURL` until a session restores
/// it, so `recoverAfterCrash` can restore it after a run that never got to.
public final class HALDeviceProvider: PCMDeviceProvider, @unchecked Sendable {
    public let deviceUID: String
    public let deviceName: String
    private let hogMode: Bool
    private let restoreRecordURL: URL
    private let queue = DispatchQueue(label: "\(bundleIdentifier).device-watch")
    private let lock = NSLock()
    private let snapshots: DeviceSnapshots
    private var listener: AudioObjectPropertyListenerBlock?
    /// The device the `IsAlive` listener is on, which changes when it is plugged back in.
    private var aliveListenerDevice: AudioObjectID?
    private var stateChanged: (@Sendable (DeviceState) -> Void)?
    private var signalListeners: PropertyListeners?

    public init(
        deviceUID: String, hogMode: Bool, restoreRecordURL: URL, snapshots: DeviceSnapshots
    ) throws {
        self.deviceUID = deviceUID
        self.snapshots = snapshots
        let id = try deviceID(uid: self.deviceUID)
        deviceName =
            try id.map { try readString($0, address(kAudioObjectPropertyName)) } ?? self.deviceUID
        self.hogMode = hogMode
        self.restoreRecordURL = restoreRecordURL
    }

    /// `uid`, or for nil the UID of the system's default output now. Resolved once, so when that
    /// device goes away playback pauses instead of following macOS to another one.
    public static func resolve(_ uid: String?) throws -> String {
        if let uid { return uid }
        let id = try AudioDevice.defaultOutputID()
        guard id != kAudioObjectUnknown else { throw HALDeviceProviderError.noDefaultOutput }
        return try readString(id, address(kAudioDevicePropertyDeviceUID))
    }

    /// Whether the device `uid` takes hog mode when first seen, from its transport type, or nil
    /// when it isn't connected (ADR 0037).
    public static func hogsByDefault(_ uid: String) throws -> Bool? {
        guard let id = try deviceID(uid: uid) else { return nil }
        return hogsByDefault(
            transport: try readScalar(id, address(kAudioDevicePropertyTransportType)))
    }

    /// An external interface is what a DAC plays bit-perfect through. The built-in output,
    /// AirPlay, Bluetooth, HDMI, DisplayPort, virtual and aggregate devices aren't, and hogging
    /// them turns off the Mac's volume keys for them.
    static func hogsByDefault(transport: UInt32) -> Bool {
        [
            kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt,
            kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypePCI,
            kAudioDeviceTransportTypeAVB,
        ].contains(transport)
    }

    public func open() throws -> (any PCMDevice)? {
        guard let id = try liveDeviceID() else { return nil }
        return try lock.withLock {
            let records = try readRestoreRecords(restoreRecordURL)
            let snapshot = try snapshots.original(of: deviceUID, recorded: records) {
                try HALDevice.snapshot(of: id, uid: deviceUID)
            }
            let device = try HALDevice(
                id: id, name: deviceName, hogMode: hogMode, restoring: snapshot)
            // Written only once the device is held, and for every session, since closing the last
            // one removed it.
            try writeRestoreRecords(adding(snapshot, to: records), to: restoreRecordURL)
            snapshots.keep(snapshot)
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

    public func watch(
        _ changed: @escaping @Sendable () -> Void,
        state: @escaping @Sendable (DeviceState) -> Void
    ) throws {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.followDevice()
            changed()
            self?.reportState()
        }
        let signalBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.reportState()
        }
        lock.withLock {
            listener = block
            stateChanged = state
            signalListeners = PropertyListeners(
                HALPropertyListening(), queue: queue, block: signalBlock)
        }
        var devices = address(kAudioHardwarePropertyDevices)
        try throwIfError(
            "AudioObjectAddPropertyListenerBlock(devices)",
            AudioObjectAddPropertyListenerBlock(systemObject, &devices, queue, block))
        followDevice()
        // On the queue, after any listener already queued, so states arrive in order.
        queue.async { [weak self] in self?.reportState() }
    }

    /// Reads the device's state, moves the signal listeners to what it has now, and reports it.
    /// Runs on the queue only, which is what serializes `signalListeners`; the lock covers just
    /// the copy, so no HAL call waits on it.
    private func reportState() {
        let watching = lock.withLock {
            () -> (@Sendable (DeviceState) -> Void, PropertyListeners)? in
            guard let stateChanged, let signalListeners else { return nil }
            return (stateChanged, signalListeners)
        }
        guard let (stateChanged, signalListeners) = watching else { return }
        let state: DeviceState
        do {
            if let id = try liveDeviceID() {
                do {
                    let (signal, keys) = try readSignal(of: id)
                    signalListeners.set(keys)
                    state = .connected(signal)
                } catch {
                    signalListeners.set(deviceSignalKeys(id))
                    throw error
                }
            } else {
                signalListeners.set([])
                state = .notConnected
            }
        } catch {
            logger.error("can't read \(self.deviceName)'s state: \(error)")
            state = .unreadable("\(error)")
        }
        stateChanged(state)
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
        let signalListeners = lock.withLock { () -> PropertyListeners? in
            guard let listener else { return nil }
            var devices = address(kAudioHardwarePropertyDevices)
            removeListener(listener, from: systemObject, &devices)
            if let device = aliveListenerDevice {
                var alive = address(kAudioDevicePropertyDeviceIsAlive)
                removeListener(listener, from: device, &alive)
            }
            self.listener = nil
            aliveListenerDevice = nil
            stateChanged = nil
            defer { self.signalListeners = nil }
            return self.signalListeners
        }
        // After a `reportState` already running finishes; one queued later finds nothing to do.
        queue.sync { signalListeners?.set([]) }
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
        guard let snapshot = snapshots.snapshot(of: deviceUID) else { return }
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

    func configure(sampleRateHz: Double, channels: UInt32, minimumBits: UInt32) throws
        -> DeviceFormat
    {
        try device.configure(
            sampleRateHz: sampleRateHz, channels: channels, minimumBits: minimumBits)
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
