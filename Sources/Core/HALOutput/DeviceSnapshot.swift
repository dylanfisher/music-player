import CoreAudio
import Foundation
import StrictKeys

/// How a device and the system's default outputs were before playback changed them, by UID, since
/// a device's object ID changes when it is plugged back in.
struct DeviceSnapshot: Codable, Equatable {
    var deviceUID: String
    var sampleRateHz: Double
    var physicalFormat: StoredFormat
    /// Nil when there was no default, which `restoreDefaults` leaves alone.
    var defaultOutputUID: String?
    var defaultSystemOutputUID: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case deviceUID, sampleRateHz, physicalFormat, defaultOutputUID, defaultSystemOutputUID
    }

    init(
        deviceUID: String, sampleRateHz: Double, physicalFormat: StoredFormat,
        defaultOutputUID: String?, defaultSystemOutputUID: String?
    ) {
        self.deviceUID = deviceUID
        self.sampleRateHz = sampleRateHz
        self.physicalFormat = physicalFormat
        self.defaultOutputUID = defaultOutputUID
        self.defaultSystemOutputUID = defaultSystemOutputUID
    }

    init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        deviceUID = try container.decode(String.self, forKey: .deviceUID)
        sampleRateHz = try container.decode(Double.self, forKey: .sampleRateHz)
        physicalFormat = try container.decode(StoredFormat.self, forKey: .physicalFormat)
        defaultOutputUID = try container.decodeIfPresent(String.self, forKey: .defaultOutputUID)
        defaultSystemOutputUID = try container.decodeIfPresent(
            String.self, forKey: .defaultSystemOutputUID)
    }
}

/// The snapshot each device got the first time this run opened it, by UID. The app makes a new
/// provider for every change of output settings, and one store serves them all, so a later
/// provider restores the device to how it was before playback, not to how a session that was
/// still restoring it left it.
/// Unchecked: `snapshots` is read and written only inside `lock`.
public final class DeviceSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [String: DeviceSnapshot] = [:]

    public init() {}

    func snapshot(of uid: String) -> DeviceSnapshot? { lock.withLock { snapshots[uid] } }

    func all() -> [DeviceSnapshot] { lock.withLock { Array(snapshots.values) } }

    /// What a session on `uid` restores: the snapshot this run kept, else the record an earlier
    /// run couldn't restore, which holds the state from before that run, else `current()`.
    func original(
        of uid: String, recorded: [DeviceSnapshot], current: () throws -> DeviceSnapshot
    ) rethrows -> DeviceSnapshot {
        if let kept = snapshot(of: uid) { return kept }
        return try recorded.first { $0.deviceUID == uid } ?? current()
    }

    /// Keeps `snapshot` unless its device already has one, which is older.
    func keep(_ snapshot: DeviceSnapshot) {
        lock.withLock {
            if snapshots[snapshot.deviceUID] == nil { snapshots[snapshot.deviceUID] = snapshot }
        }
    }
}

/// The fields of an `AudioStreamBasicDescription`, which isn't `Codable`.
struct StoredFormat: Codable, Equatable {
    var sampleRate: Double
    var formatID: UInt32
    var formatFlags: UInt32
    var bytesPerPacket: UInt32
    var framesPerPacket: UInt32
    var bytesPerFrame: UInt32
    var channelsPerFrame: UInt32
    var bitsPerChannel: UInt32

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sampleRate, formatID, formatFlags, bytesPerPacket, framesPerPacket, bytesPerFrame
        case channelsPerFrame, bitsPerChannel
    }

    init(_ format: AudioStreamBasicDescription) {
        sampleRate = format.mSampleRate
        formatID = format.mFormatID
        formatFlags = format.mFormatFlags
        bytesPerPacket = format.mBytesPerPacket
        framesPerPacket = format.mFramesPerPacket
        bytesPerFrame = format.mBytesPerFrame
        channelsPerFrame = format.mChannelsPerFrame
        bitsPerChannel = format.mBitsPerChannel
    }

    init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        sampleRate = try container.decode(Double.self, forKey: .sampleRate)
        formatID = try container.decode(UInt32.self, forKey: .formatID)
        formatFlags = try container.decode(UInt32.self, forKey: .formatFlags)
        bytesPerPacket = try container.decode(UInt32.self, forKey: .bytesPerPacket)
        framesPerPacket = try container.decode(UInt32.self, forKey: .framesPerPacket)
        bytesPerFrame = try container.decode(UInt32.self, forKey: .bytesPerFrame)
        channelsPerFrame = try container.decode(UInt32.self, forKey: .channelsPerFrame)
        bitsPerChannel = try container.decode(UInt32.self, forKey: .bitsPerChannel)
    }

    var basicDescription: AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: formatID, mFormatFlags: formatFlags,
            mBytesPerPacket: bytesPerPacket, mFramesPerPacket: framesPerPacket,
            mBytesPerFrame: bytesPerFrame, mChannelsPerFrame: channelsPerFrame,
            mBitsPerChannel: bitsPerChannel, mReserved: 0)
    }
}
