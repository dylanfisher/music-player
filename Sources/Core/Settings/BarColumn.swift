import StrictKeys

/// One column of a `BarLayout`: its parts, left to right or top to bottom when it stacks, how
/// wide it is and where its parts sit in it.
public struct BarColumn<Part: Codable & Hashable & Sendable>: Codable, Equatable, Sendable {
    public var parts: [Part]
    public var width: BarWidth
    public var alignment: BarAlignment
    /// Whether the tall style puts the parts one over another rather than side by side.
    public var stacks: Bool

    public init(parts: [Part], width: BarWidth, alignment: BarAlignment, stacks: Bool = false) {
        self.parts = parts
        self.width = width
        self.alignment = alignment
        self.stacks = stacks
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case parts, width, alignment, stacks
    }

    public init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        parts = try container.decode([Part].self, forKey: .parts)
        width = try container.decode(BarWidth.self, forKey: .width)
        alignment = try container.decode(BarAlignment.self, forKey: .alignment)
        stacks = try container.decode(Bool.self, forKey: .stacks)
    }
}

/// A column's width: `"flexible"`, sharing the width the fixed columns leave equally with the
/// other flexible columns, or a number of points.
public enum BarWidth: Codable, Hashable, Sendable {
    case flexible
    case fixed(Int)

    /// A fixed width the config accepts, in points: from about one part's width to most of the
    /// 2015 MacBook Pro's screen.
    public static let fixedRangePoints = 16...1200
    static let flexibleName = "flexible"

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Not a number means the other spelling, whose decode below throws if it isn't one.
        if let points = try? container.decode(Int.self) {
            self = .fixed(points)
            return
        }
        let text = try container.decode(String.self)
        guard text == Self.flexibleName else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "\"\(text)\" isn't \"\(Self.flexibleName)\" or a number of points"
            )
        }
        self = .flexible
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .flexible: try container.encode(Self.flexibleName)
        case .fixed(let points): try container.encode(points)
        }
    }
}

/// Where a column's parts sit in it when it's wider than they are.
public enum BarAlignment: String, Codable, CaseIterable, Sendable {
    case leading, center, trailing

    public var title: String {
        switch self {
        case .leading: "Left"
        case .center: "Center"
        case .trailing: "Right"
        }
    }
}
