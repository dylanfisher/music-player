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
    /// Every tag the value goes to; a field can go to several (styles to `STYLE` and `MOOD`).
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
        try rejectUnknownKeys(decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
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
