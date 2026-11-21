import StrictKeys

/// The phones and computers paired with the web remote (ADR 0214). Each keeps its token, and the
/// Mac only the token's SHA-256, so the state file holds no secret: a hash checks a token but
/// can't be sent as one. Each hash once, at most `capacity` of them.
public struct RemoteDevices: SettingValue {
    public static let capacity = 32
    /// Most characters in a device's name, which the page makes up ("iPhone, Safari").
    static let nameCharacters = 64

    public struct Device: Codable, Equatable, Sendable {
        public var name: String
        /// The token's SHA-256, as 64 lowercase hex digits.
        public var tokenHash: String
        /// Seconds since 1970.
        public var pairedSeconds: Double
        public var lastSeenSeconds: Double

        public init(name: String, tokenHash: String, pairedSeconds: Double, lastSeenSeconds: Double)
        {
            self.name = name
            self.tokenHash = tokenHash
            self.pairedSeconds = pairedSeconds
            self.lastSeenSeconds = lastSeenSeconds
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case name, tokenHash, pairedSeconds, lastSeenSeconds
        }

        public init(from decoder: any Decoder) throws {
            let container = try strictContainer(decoder, CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            tokenHash = try container.decode(String.self, forKey: .tokenHash)
            pairedSeconds = try container.decode(Double.self, forKey: .pairedSeconds)
            lastSeenSeconds = try container.decode(Double.self, forKey: .lastSeenSeconds)
        }

        /// Why `name` can't be a device's name, nil when it can: empty, too long, or holding a
        /// control character, since the Settings window shows it.
        public static func nameProblem(_ name: String) -> String? {
            if name.isEmpty { return "the name is empty" }
            if name.count > RemoteDevices.nameCharacters {
                return "the name is over \(RemoteDevices.nameCharacters) characters"
            }
            if name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                return "the name holds a control character"
            }
            return nil
        }
    }

    public var devices: [Device]

    public init(devices: [Device]) {
        self.devices = devices
    }

    public init(from decoder: any Decoder) throws {
        devices = try decoder.singleValueContainer().decode([Device].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(devices)
    }

    public static var typeName: String {
        "a list of devices (name, tokenHash, pairedSeconds, lastSeenSeconds)"
    }
    public static var kind: SettingKind { .windowState }

    public func problem() -> String? {
        if devices.count > Self.capacity { return "more than \(Self.capacity) devices" }
        var hashes = Set<String>()
        for (index, device) in devices.enumerated() {
            if let problem = Device.nameProblem(device.name) { return "[\(index)]: \(problem)" }
            let hex = device.tokenHash.utf8
            guard hex.count == 64,
                hex.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) })
            else { return "[\(index)]: tokenHash isn't 64 lowercase hex digits" }
            guard hashes.insert(device.tokenHash).inserted else {
                return "[\(index)]: the token hash is listed twice"
            }
        }
        return nil
    }
}
