import StrictKeys

/// Where the palette was dragged, kept relative to a screen: the share of the room the panel
/// leaves across and down the visible area, each from 0 to 1, so it always lands wholly on
/// whichever screen opens it next.
public struct PalettePlace: SettingValue {
    public var across: Double
    public var down: Double

    public init(across: Double, down: Double) {
        self.across = across
        self.down = down
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case across, down
    }

    public init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        across = try container.decode(Double.self, forKey: .across)
        down = try container.decode(Double.self, forKey: .down)
    }

    public static var typeName: String { "a palette place (across, down)" }
    public static var kind: SettingKind { .windowState }

    public func problem() -> String? {
        (0...1).contains(across) && (0...1).contains(down)
            ? nil : "across and down must be from 0 to 1, not \(across) and \(down)"
    }
}
