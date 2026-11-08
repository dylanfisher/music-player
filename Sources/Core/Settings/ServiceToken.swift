import Foundation

/// `recommender.token`: the bearer token music-recommender's API takes (ADR 0144), a secret
/// kept as the Discogs token is (ADR 0137): only in the config file, and only in the service's
/// `Authorization` header. Printing it, by interpolation, `String(reflecting:)` or `dump`,
/// gives `<service token>`, so no log line, error or test message can carry its value.
public struct ServiceToken: SettingValue, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    /// The token's text, for the one header built from it.
    public let secret: String

    /// The longest token taken.
    static let lengthCap = 1024

    init(_ secret: String) { self.secret = secret }

    public init(from decoder: any Decoder) throws {
        secret = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(secret)
    }

    public var description: String { "<service token>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }

    public static var typeName: String { "a service token (text)" }
    public static var kind: SettingKind { .secret }

    /// Never quotes the value, since the problem is shown and logged.
    public func problem() -> String? {
        let visible = secret.utf8.allSatisfy { (0x21...0x7E).contains($0) }
        return visible && (1...Self.lengthCap).contains(secret.utf8.count)
            ? nil
            : "the token must be 1 to \(Self.lengthCap) visible ASCII characters, with no spaces"
    }
}
