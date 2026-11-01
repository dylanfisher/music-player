import Settings

/// The app's answer to a `ScriptRequest`.
public enum ScriptReply: Equatable, Sendable {
    /// Ran, with what it did when that isn't obvious: "Playing 9 tracks".
    case done(String?)
    case failed(String)
    case status(ScriptStatus)
}

extension ScriptReply: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, message, status
    }

    private enum Kind: String, Codable {
        case done, failed, status
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .done:
            try onlyKeys(container, [.kind, .message])
            self = .done(try container.decodeIfPresent(String.self, forKey: .message))
        case .failed:
            try onlyKeys(container, [.kind, .message])
            self = .failed(try container.decode(String.self, forKey: .message))
        case .status:
            try onlyKeys(container, [.kind, .status])
            self = .status(try container.decode(ScriptStatus.self, forKey: .status))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .done(let message):
            try container.encode(Kind.done, forKey: .kind)
            try container.encodeIfPresent(message, forKey: .message)
        case .failed(let message):
            try container.encode(Kind.failed, forKey: .kind)
            try container.encode(message, forKey: .message)
        case .status(let status):
            try container.encode(Kind.status, forKey: .kind)
            try container.encode(status, forKey: .status)
        }
    }
}

/// Throws when `container` has a key its kind doesn't take, as `rejectUnknownKeys` does for
/// keys no kind takes.
func onlyKeys<Key: CodingKey & Hashable>(
    _ container: KeyedDecodingContainer<Key>, _ allowed: Set<Key>
)
    throws
{
    if let extra = container.allKeys.first(where: { !allowed.contains($0) }) {
        throw DecodingError.dataCorruptedError(
            forKey: extra, in: container, debugDescription: "not taken with this kind")
    }
}
