/// A table's column widths in points, by column identifier: `{"album": 260, "state": 340}`. A
/// column the table no longer has is ignored when it opens, and one not listed keeps its own
/// width.
public struct ColumnWidths: SettingValue {
    public var widths: [String: Double]

    public init(_ widths: [String: Double] = [:]) { self.widths = widths }

    public init(from decoder: any Decoder) throws {
        widths = try decoder.singleValueContainer().decode([String: Double].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(widths)
    }

    public static var typeName: String { "column widths by column name" }
    public static var kind: SettingKind { .windowState }

    public func problem() -> String? {
        for name in widths.keys.sorted() {
            if let width = widths[name], !(width > 0) {
                return "\(name): width must be positive, not \(width)"
            }
        }
        return nil
    }
}
