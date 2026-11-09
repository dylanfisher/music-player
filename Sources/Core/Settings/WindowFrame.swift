import CoreGraphics

/// Where a window sits on screen, in AppKit screen coordinates (origin bottom left).
public struct WindowFrame: SettingValue {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case x, y, width, height
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decode(Double.self, forKey: .x)
        y = try container.decode(Double.self, forKey: .y)
        width = try container.decode(Double.self, forKey: .width)
        height = try container.decode(Double.self, forKey: .height)
    }

    public static var typeName: String { "a window frame (x, y, width, height)" }
    public static var kind: SettingKind { .windowState }

    public func problem() -> String? {
        width > 0 && height > 0 ? nil : "width and height must be positive, not \(width)x\(height)"
    }
}
