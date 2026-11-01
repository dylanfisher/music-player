import Log
import Playback

private let logger = moduleLogger()

/// One output device's own settings, by its Core Audio UID, and what it last reported it can take.
public struct DeviceProfile: Codable, Equatable, Sendable {
    public var uid: String
    public var hogMode: Bool
    public var digitalVolume: Bool
    /// The digital volume, at or below 0; 0 is full.
    public var volumeDecibels: Double
    /// Nil until the device first reports them.
    public var formats: DeviceFormats?

    init(
        uid: String, hogMode: Bool, digitalVolume: Bool, volumeDecibels: Double,
        formats: DeviceFormats?
    ) {
        self.uid = uid
        self.hogMode = hogMode
        self.digitalVolume = digitalVolume
        self.volumeDecibels = volumeDecibels
        self.formats = formats
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case uid, hogMode, digitalVolume, volumeDecibels, formats
    }

    private enum FormatsKeys: String, CodingKey, CaseIterable {
        case sampleRatesHz, formats
    }

    private enum FormatKeys: String, CodingKey, CaseIterable {
        case formatID, sampleRateHz, bitsPerChannel, channels, isFloat, isMixable
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uid = try container.decode(String.self, forKey: .uid)
        hogMode = try container.decode(Bool.self, forKey: .hogMode)
        digitalVolume = try container.decode(Bool.self, forKey: .digitalVolume)
        volumeDecibels = try container.decode(Double.self, forKey: .volumeDecibels)
        formats =
            try !container.contains(.formats) || container.decodeNil(forKey: .formats)
            ? nil : try Self.formats(from: container.superDecoder(forKey: .formats))
    }

    /// Playback's types aren't `Codable`, so their keys are checked here, at every level.
    private static func formats(from decoder: any Decoder) throws -> DeviceFormats {
        try rejectUnknownKeys(decoder, FormatsKeys.self)
        let container = try decoder.container(keyedBy: FormatsKeys.self)
        var list = try container.nestedUnkeyedContainer(forKey: .formats)
        var formats: [PhysicalFormat] = []
        while !list.isAtEnd {
            let decoder = try list.superDecoder()
            try rejectUnknownKeys(decoder, FormatKeys.self)
            let format = try decoder.container(keyedBy: FormatKeys.self)
            formats.append(
                PhysicalFormat(
                    formatID: try format.decode(String.self, forKey: .formatID),
                    sampleRateHz: try format.decode(
                        ClosedRange<Double>.self, forKey: .sampleRateHz),
                    bitsPerChannel: try format.decode(UInt32.self, forKey: .bitsPerChannel),
                    channels: try format.decode(UInt32.self, forKey: .channels),
                    isFloat: try format.decode(Bool.self, forKey: .isFloat),
                    isMixable: try format.decode(Bool.self, forKey: .isMixable)))
        }
        return DeviceFormats(
            sampleRatesHz: try container.decode([ClosedRange<Double>].self, forKey: .sampleRatesHz),
            formats: formats)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uid, forKey: .uid)
        try container.encode(hogMode, forKey: .hogMode)
        try container.encode(digitalVolume, forKey: .digitalVolume)
        try container.encode(volumeDecibels, forKey: .volumeDecibels)
        guard let formats else { return }
        var reported = container.nestedContainer(keyedBy: FormatsKeys.self, forKey: .formats)
        try reported.encode(formats.sampleRatesHz, forKey: .sampleRatesHz)
        var list = reported.nestedUnkeyedContainer(forKey: .formats)
        for format in formats.formats {
            var entry = list.nestedContainer(keyedBy: FormatKeys.self)
            try entry.encode(format.formatID, forKey: .formatID)
            try entry.encode(format.sampleRateHz, forKey: .sampleRateHz)
            try entry.encode(format.bitsPerChannel, forKey: .bitsPerChannel)
            try entry.encode(format.channels, forKey: .channels)
            try entry.encode(format.isFloat, forKey: .isFloat)
            try entry.encode(format.isMixable, forKey: .isMixable)
        }
    }

    fileprivate func problem() -> String? {
        if uid.isEmpty { return "an empty uid" }
        if uid.utf8.count > DeviceProfiles.uidBytes {
            return "a uid over \(DeviceProfiles.uidBytes) bytes"
        }
        if !volumeDecibels.isFinite || volumeDecibels > 0 {
            return "volumeDecibels \(volumeDecibels) isn't 0 or below"
        }
        guard let formats else { return nil }
        if formats.sampleRatesHz.count > DeviceProfiles.formatCapacity
            || formats.formats.count > DeviceProfiles.formatCapacity
        {
            return "more than \(DeviceProfiles.formatCapacity) rates or formats"
        }
        return nil
    }
}

/// The output settings the config file holds, which a device seen for the first time starts from.
public struct OutputConfig: Equatable, Sendable {
    public var hogMode: Bool
    public var digitalVolume: Bool

    public init(hogMode: Bool, digitalVolume: Bool) {
        self.hogMode = hogMode
        self.digitalVolume = digitalVolume
    }
}

/// Each output device's profile, most recently used first, each UID once, at most `capacity`
/// (ADR 0037).
public struct DeviceProfiles: SettingValue {
    public static let capacity = 32
    /// Rates and formats kept per profile, and the longest UID, so the file has a size limit.
    static let formatCapacity = 64
    static let uidBytes = 512

    public var profiles: [DeviceProfile]

    public init(profiles: [DeviceProfile]) {
        self.profiles = profiles
    }

    public init(from decoder: any Decoder) throws {
        profiles = try decoder.singleValueContainer().decode([DeviceProfile].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(profiles)
    }

    public static var typeName: String {
        "a list of device profiles (uid, hogMode, digitalVolume, volumeDecibels, formats)"
    }
    public static var kind: SettingKind { .windowState }

    public func problem() -> String? {
        if profiles.count > Self.capacity { return "more than \(Self.capacity) profiles" }
        var seen: Set<String> = []
        for (index, profile) in profiles.enumerated() {
            if let problem = profile.problem() { return "[\(index)]: \(problem)" }
            if !seen.insert(profile.uid).inserted {
                return "[\(index)]: \"\(profile.uid)\" is listed twice"
            }
        }
        return nil
    }

    /// The profile `uid` plays with. A device not seen before starts from `config` at full volume.
    /// The config's output settings show the device in use, so when they changed without the
    /// device changing (`switched` false, which includes launch) they are an edit, and the profile
    /// takes them; when the device changed, they belong to the device before, and a profile keeps
    /// its own.
    public func profile(for uid: String, config: OutputConfig, switched: Bool) -> DeviceProfile {
        guard var profile = profiles.first(where: { $0.uid == uid }) else {
            return DeviceProfile(
                uid: uid, hogMode: config.hogMode, digitalVolume: config.digitalVolume,
                volumeDecibels: 0, formats: nil)
        }
        if !switched {
            profile.hogMode = config.hogMode
            profile.digitalVolume = config.digitalVolume
        }
        return profile
    }

    /// With `profile` as the most recently used, and the least recently used dropped past
    /// `capacity`.
    public func using(_ profile: DeviceProfile) -> DeviceProfiles {
        DeviceProfiles(
            profiles: Array(
                ([profile] + profiles.filter { $0.uid != profile.uid }).prefix(Self.capacity)))
    }

    /// With `formats` recorded for `uid`, in place, or nil when it already holds them or has no
    /// profile. A device reporting more than `formatCapacity` keeps the first ones, which only
    /// the check before it next reports reads.
    public func reporting(_ formats: DeviceFormats, for uid: String) -> DeviceProfiles? {
        guard let index = profiles.firstIndex(where: { $0.uid == uid }) else { return nil }
        var kept = formats
        if formats.sampleRatesHz.count > Self.formatCapacity
            || formats.formats.count > Self.formatCapacity
        {
            logger.notice(
                "\(uid) reports \(formats.sampleRatesHz.count) rates and \(formats.formats.count) formats; its profile keeps the first \(Self.formatCapacity) of each"
            )
            kept.sampleRatesHz = Array(formats.sampleRatesHz.prefix(Self.formatCapacity))
            kept.formats = Array(formats.formats.prefix(Self.formatCapacity))
        }
        guard profiles[index].formats != kept else { return nil }
        var next = self
        next.profiles[index].formats = kept
        return next
    }
}
