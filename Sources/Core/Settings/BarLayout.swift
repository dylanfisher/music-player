/// A bar's parts in columns, like a row of flexbox items: columns on the leading side, one in
/// the center that the bar centers on the window, and columns on the trailing side (ADR 0085).
/// Generic over the parts, so each bar the builder edits has its own; the settings window holds
/// them by their names in the config file.
public struct BarLayout<Part: Codable & Hashable & Sendable>: Codable, Equatable, Sendable {
    public var leading: [BarColumn<Part>]
    public var center: BarColumn<Part>
    public var trailing: [BarColumn<Part>]

    public init(
        leading: [BarColumn<Part>] = [], center: BarColumn<Part>,
        trailing: [BarColumn<Part>] = []
    ) {
        self.leading = leading
        self.center = center
        self.trailing = trailing
    }

    /// Every column with its place, left to right.
    public var columns: [(place: BarPlace, column: BarColumn<Part>)] {
        leading.enumerated().map { (.leading($0.offset), $0.element) } + [(.center, center)]
            + trailing.enumerated().map { (.trailing($0.offset), $0.element) }
    }

    /// The column at `place`, or nil for a side column past the end.
    public subscript(place: BarPlace) -> BarColumn<Part>? {
        switch place {
        case .leading(let index): leading.indices.contains(index) ? leading[index] : nil
        case .center: center
        case .trailing(let index): trailing.indices.contains(index) ? trailing[index] : nil
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case leading, center, trailing
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        leading = try container.decode([BarColumn<Part>].self, forKey: .leading)
        center = try container.decode(BarColumn<Part>.self, forKey: .center)
        trailing = try container.decode([BarColumn<Part>].self, forKey: .trailing)
    }
}

extension BarLayout: SettingValue where Part: BarPart {
    public static var typeName: String {
        "a bar layout (leading, center and trailing columns of parts, width, alignment, stacks)"
    }
    public static var kind: SettingKind {
        .barLayout(Part.allCases.map { SettingKind.Choice(rawValue: $0.rawValue, title: $0.title) })
    }

    /// Everything wrong with the layout, in column order.
    public var problems: [BarLayoutProblem] {
        var problems: [BarLayoutProblem] = []
        var seen: Set<Part> = []
        for (place, column) in columns {
            if column.parts.isEmpty { problems.append(.emptyColumn(place)) }
            if case .fixed(let points) = column.width, !BarWidth.fixedRangePoints.contains(points) {
                problems.append(.widthOutOfRange(place, points: points))
            }
            for part in column.parts {
                if !seen.insert(part).inserted {
                    problems.append(.repeatedPart(part.rawValue, place))
                }
                if column.stacks, part.fillsHeight {
                    problems.append(.stackedPartFillsHeight(part.rawValue, place))
                }
            }
        }
        return problems
    }

    public func problem() -> String? {
        problems.isEmpty ? nil : problems.map(\.description).joined(separator: "; ")
    }
}

/// Where a column is in a `BarLayout`.
public enum BarPlace: Hashable, Sendable, CustomStringConvertible {
    case leading(Int)
    case center
    case trailing(Int)

    public var description: String {
        switch self {
        case .leading(let index): "leading column \(index + 1)"
        case .center: "the center column"
        case .trailing(let index): "trailing column \(index + 1)"
        }
    }
}
