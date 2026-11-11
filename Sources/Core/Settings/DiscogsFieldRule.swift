/// Where one Discogs field is written, and how (ADR 0132).
public struct DiscogsFieldRule: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        /// The tag becomes Discogs's value, where Discogs has one.
        case replace
        /// Discogs's value is written only to a tag that's empty.
        case fillEmpty
        case off
    }

    public var mode: Mode
    /// Every tag the value goes to; a field can go to several (the label to `LABEL` and
    /// `GROUPING`).
    public var targets: [DiscogsTarget]
    public var format: DiscogsFieldFormat

    public init(
        _ mode: Mode, _ targets: [DiscogsTarget], format: DiscogsFieldFormat = DiscogsFieldFormat()
    ) {
        self.mode = mode
        self.targets = targets
        self.format = format
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case mode
        case targets = "to"
        case format
    }

    public init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        mode = try container.decode(Mode.self, forKey: .mode)
        targets = try container.decode([DiscogsTarget].self, forKey: .targets)
        format =
            try container.decodeIfPresent(DiscogsFieldFormat.self, forKey: .format)
            ?? DiscogsFieldFormat()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(targets, forKey: .targets)
        if format != DiscogsFieldFormat() { try container.encode(format, forKey: .format) }
    }
}

extension DiscogsFieldRule.Mode {
    /// The modes in the order the Field Mapping sheet and Settings ▸ Tagging list them.
    public static let shown: [DiscogsFieldRule.Mode] = [.replace, .fillEmpty, .off]

    public var title: String {
        switch self {
        case .replace: "Replace Tag"
        case .fillEmpty: "Fill Empty Tag"
        case .off: "Off"
        }
    }
}

extension DiscogsFieldRule {
    /// The rule's parts as the Field Mapping sheet's columns and Settings ▸ Tagging's rows
    /// name them.
    public static let modeTitle = "Mode"
    public static let targetsTitle = "Tags"
    public static let joinTitle = "Join"
    public static let templateTitle = "Template"
}

extension DiscogsFieldRule {
    /// Sets the text between a list's values, as both editors take it typed: empty text is no
    /// join.
    public mutating func setJoin(_ text: String) {
        format.join = text.isEmpty ? nil : text
    }

    /// Sets the template; empty text is none, which writes the field's own value.
    public mutating func setTemplate(_ text: String) {
        format.template = text.isEmpty ? nil : text
    }
}
