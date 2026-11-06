/// Where a Get Info window's top left corner was moved to, in AppKit screen coordinates
/// (origin bottom left). The corner rather than the frame: the window grows once its files are
/// read.
public struct InfoWindowPlace: SettingValue {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case x, y
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decode(Double.self, forKey: .x)
        y = try container.decode(Double.self, forKey: .y)
    }

    public static var typeName: String { "a window's top left corner (x, y)" }
    public static var kind: SettingKind { .windowState }
}
