import Foundation

/// What sets one secret apart from another: what it prints as, its name in errors, and what
/// makes its text unusable.
public protocol SecretRole: Sendable {
    /// What printing the secret gives, such as `<service token>`.
    static var redacted: String { get }
    /// Completes "expected …" in an error.
    static var typeName: String { get }
    /// Why `secret` can't be used, or nil. Never quotes it, since the problem is shown and logged.
    static func problem(_ secret: String) -> String?
}

/// A secret's text, kept only in the config file (ADR 0137) and sent only in the header of the
/// one service that takes it. Printing it, by interpolation, `String(reflecting:)`, `dump` or a
/// `Mirror`, gives its role's `redacted` text, so no log line, error or test message can carry
/// its value; a leak fixed here is fixed for every secret. Stored as a bare string.
public struct Secret<Role: SecretRole>: SettingValue, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    /// The secret's text, for the one header built from it.
    public let secret: String

    init(_ secret: String) { self.secret = secret }

    public init(from decoder: any Decoder) throws {
        secret = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(secret)
    }

    public var description: String { Role.redacted }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }

    public static var typeName: String { Role.typeName }
    public static var kind: SettingKind { .secret }

    public func problem() -> String? { Role.problem(secret) }
}
