/// A color as the config file writes it: `"#RRGGBB"`, or `"#RRGGBBAA"` with its opacity, in
/// sRGB. Stored as the string the owner wrote.
public struct HexColor: SettingValue {
    public var text: String

    public init(_ text: String) { self.text = text }

    /// The color of these components, each from 0 to 1, as `"#RRGGBBAA"`.
    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        text =
            "#"
            + [red, green, blue, alpha].map { component in
                let byte = Int((min(max(component, 0), 1) * 255).rounded())
                let digits = String(byte, radix: 16, uppercase: true)
                return digits.count == 1 ? "0" + digits : digits
            }.joined()
    }

    public init(from decoder: any Decoder) throws {
        text = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }

    public static var typeName: String { "a color, \"#RRGGBB\" or \"#RRGGBBAA\"" }
    public static var kind: SettingKind { .color }

    public func problem() -> String? {
        components == nil
            ? "\(text.debugDescription) isn't a color; write \"#RRGGBB\", or \"#RRGGBBAA\" with"
                + " its opacity"
            : nil
    }

    /// Red, green, blue and alpha, each from 0 to 1; nil when the text isn't a color. Without
    /// its last pair the color is opaque.
    public var components: (red: Double, green: Double, blue: Double, alpha: Double)? {
        guard text.first == "#" else { return nil }
        let digits = Array(text.dropFirst())
        guard digits.count == 6 || digits.count == 8 else { return nil }
        var bytes: [Double] = []
        for start in stride(from: 0, to: digits.count, by: 2) {
            guard digits[start].isHexDigit, digits[start + 1].isHexDigit,
                let byte = UInt8(String(digits[start...start + 1]), radix: 16)
            else { return nil }
            bytes.append(Double(byte) / 255)
        }
        return (bytes[0], bytes[1], bytes[2], bytes.count == 4 ? bytes[3] : 1)
    }
}
