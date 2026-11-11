import StrictKeys

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
        let container = try strictContainer(decoder, CodingKeys.self)
        leading = try container.decode([BarColumn<Part>].self, forKey: .leading)
        center = try container.decode(BarColumn<Part>.self, forKey: .center)
        trailing = try container.decode([BarColumn<Part>].self, forKey: .trailing)
    }
}

extension BarLayout {
    /// Everything wrong with the layout, in column order. `fillsHeight` says whether a part is
    /// as tall as the bar, and `title` names it as the settings window does.
    public func problems(
        fillsHeight: (Part) -> Bool, title: (Part) -> String
    ) -> [BarLayoutProblem] {
        var problems: [BarLayoutProblem] = []
        var seen: Set<Part> = []
        for (place, column) in columns {
            if case .fixed(let points) = column.width, !BarWidth.fixedRangePoints.contains(points) {
                problems.append(.widthOutOfRange(place, points: points))
            }
            for part in column.parts {
                if !seen.insert(part).inserted {
                    problems.append(.repeatedPart(title(part), place))
                }
                // Alone, a part as tall as the bar has nothing to stack with.
                if column.stacks, column.parts.count > 1, fillsHeight(part) {
                    problems.append(.stackedPartFillsHeight(title(part), place))
                }
            }
        }
        return problems
    }
}

extension BarLayout: SettingValue where Part: BarPart {
    public static var typeName: String {
        "a bar layout (leading, center and trailing columns of parts, width, alignment, stacks)"
    }
    public static var kind: SettingKind {
        .barLayout(
            SettingKind.Bar(
                choices: Part.allCases.map {
                    SettingKind.Choice(rawValue: $0.rawValue, title: $0.title)
                }, fillsHeight: Part.allCases.filter(\.fillsHeight).map(\.rawValue),
                stackTitle: Part.stackTitle, centerHelp: Part.centerHelp,
                stackCapPoints: Part.stackCapPoints))
    }

    /// Everything wrong with the layout, in column order.
    public var problems: [BarLayoutProblem] {
        problems(fillsHeight: \.fillsHeight, title: \.title)
    }

    /// The first few problems, and how many more, so a hostile layout can't fill the banner.
    public func problem() -> String? {
        let problems = problems
        guard !problems.isEmpty else { return nil }
        let shown = problems.prefix(BarLayoutProblem.shownCount).map(\.description)
        let more = problems.count - shown.count
        return shown.joined(separator: "; ") + (more > 0 ? "; \(more) more" : "")
    }
}

/// Where a column is in a `BarLayout`.
public enum BarPlace: Hashable, Sendable, CustomStringConvertible {
    case leading(Int)
    case center
    case trailing(Int)

    /// The column by where it is, each side counted left to right: "the first column on the
    /// left", "the center column", "the second column on the right".
    public var description: String {
        switch self {
        case .leading(let index): "the \(ordinal(index + 1)) column on the left"
        case .center: "the center column"
        case .trailing(let index): "the \(ordinal(index + 1)) column on the right"
        }
    }
}

/// "first" to "tenth" in words, then "11th", "21st" and on.
private func ordinal(_ number: Int) -> String {
    let words = [
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth",
        "tenth",
    ]
    if words.indices.contains(number - 1) { return words[number - 1] }
    let suffix =
        (11...13).contains(number % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][number % 10] ?? "th"
    return "\(number)\(suffix)"
}
