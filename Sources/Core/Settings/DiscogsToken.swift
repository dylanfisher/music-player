import Foundation

/// A Discogs personal access token, a secret (ADR 0137). It is kept only in the
/// config file and goes only into the Discogs API's `Authorization` header. Printing it, by
/// interpolation, `String(reflecting:)` or `dump`, gives `<Discogs token>`, so no log line,
/// error or test message can carry its value.
public struct DiscogsToken: SettingValue, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    /// The token's text, for the one header built from it.
    public let secret: String

    init(_ secret: String) { self.secret = secret }

    public init(from decoder: any Decoder) throws {
        secret = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(secret)
    }

    public var description: String { "<Discogs token>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }

    public static var typeName: String { "a Discogs token (text)" }
    public static var kind: SettingKind { .secret }

    /// Never quotes the value. A header value can't hold a line break or a character outside
    /// printable ASCII, and a token has no space.
    public func problem() -> String? {
        if secret.trimmingCharacters(in: .whitespaces).isEmpty { return "the token is empty" }
        guard secret.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            return "the token has a space, a line break or a character outside printable ASCII"
        }
        return nil
    }
}
