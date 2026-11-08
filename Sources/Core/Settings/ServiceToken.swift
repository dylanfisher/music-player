/// `recommender.token`: the bearer token music-recommender's API takes, the app's one secret
/// (ADR 0144). It prints as `***`, so a log line or an error that names the value can't show
/// it; only `rawValue` holds it. The config file holds it as a string.
public struct ServiceToken: SettingValue, RawRepresentable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    public var rawValue: String

    /// The longest token taken.
    static let lengthCap = 1024

    public init(rawValue: String) { self.rawValue = rawValue }

    init(_ text: String) { rawValue = text }

    public static var typeName: String { "a token" }
    public static var kind: SettingKind { .secret }

    /// Never quotes the text, since the problem is shown and logged.
    public func problem() -> String? {
        let visible = rawValue.utf8.allSatisfy { (0x21...0x7E).contains($0) }
        return visible && (1...Self.lengthCap).contains(rawValue.utf8.count)
            ? nil
            : "the token must be 1 to \(Self.lengthCap) visible ASCII characters, with no spaces"
    }

    public var description: String { "***" }
    public var debugDescription: String { "***" }
}
