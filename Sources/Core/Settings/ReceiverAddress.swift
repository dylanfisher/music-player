import LocalNetwork

/// `receiver.address`: a literal IPv4 or IPv6 address, never a host name, which could resolve
/// anywhere (ADR 0039). Stored as the string the owner wrote.
public struct ReceiverAddress: SettingValue {
    public var text: String

    init(_ text: String) { self.text = text }

    public init(from decoder: any Decoder) throws {
        text = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }

    public static var typeName: String { "an IP address" }
    public static var kind: SettingKind { .string }

    public func problem() -> String? {
        address == nil
            ? "\(text.debugDescription) isn't an IPv4 or IPv6 address; host names aren't taken"
            : nil
    }

    public var address: IPAddress? { IPAddress(text) }
}
