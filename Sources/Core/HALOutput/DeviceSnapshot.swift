import CoreAudio
import Foundation

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
        try rejectUnknownKeys(in: decoder, known: CodingKeys.allCases)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceUID = try container.decode(String.self, forKey: .deviceUID)
        sampleRateHz = try container.decode(Double.self, forKey: .sampleRateHz)
        physicalFormat = try container.decode(StoredFormat.self, forKey: .physicalFormat)
        defaultOutputUID = try container.decodeIfPresent(String.self, forKey: .defaultOutputUID)
        defaultSystemOutputUID = try container.decodeIfPresent(
            String.self, forKey: .defaultSystemOutputUID)
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
        try rejectUnknownKeys(in: decoder, known: CodingKeys.allCases)
        let container = try decoder.container(keyedBy: CodingKeys.self)
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

/// Fails on a key outside `known`, so a record from another build is discarded instead of half
/// read.
private func rejectUnknownKeys<Key: CodingKey>(in decoder: any Decoder, known: [Key]) throws {
    let names = Set(known.map(\.stringValue))
    let raw = try decoder.container(keyedBy: AnyKey.self)
    if let key = raw.allKeys.map(\.stringValue).sorted().first(where: { !names.contains($0) }) {
        throw DecodingError.dataCorruptedError(
            forKey: AnyKey(stringValue: key)!, in: raw, debugDescription: "unknown key")
    }
}

private struct AnyKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
