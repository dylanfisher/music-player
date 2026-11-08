import Metadata

/// How a Discogs field's value is turned into text (ADR 0132). Every part is optional in JSON;
/// one left out takes the first case named below.
public struct DiscogsFieldFormat: Codable, Equatable, Sendable {
    /// Which of an artist's names is written.
    public enum Names: String, Codable, Sendable {
        /// The artist's name on Discogs.
        case canonical
        /// The name as the release prints it (its ANV), where it has one.
        case variation
    }

    /// Whether Discogs's number after a name shared by several artists, as in "Artist (2)", is
    /// kept.
    public enum Suffixes: String, Codable, Sendable { case keep, drop }

    public enum DateForm: String, Codable, Sendable {
        /// As Discogs writes it: "1999", "1999-03-00" or "1999-03-15".
        case full
        case year
    }

    /// How a credit is written as one value.
    public enum CreditStyle: String, Codable, Sendable {
        /// "Name (Role)", as YATE writes `INVOLVEDPEOPLE` in FLAC.
        case nameRole
        /// "Role;;;Name,Name", as YATE writes it in MP4, and as ID3's involved people list
        /// holds its pairs.
        case roleNames
    }

    /// What goes between a list's values; for artists, nil keeps Discogs's join words
    /// ("Alice Coltrane Featuring Pharoah Sanders"). A list field other than an artist needs
    /// one unless every target is numbered.
    public var join: String?
    public var names: Names?
    public var suffixes: Suffixes?
    public var date: DateForm?
    /// Text with fields' tokens in braces, each replaced by that field's value in this format:
    /// the owner's `GENRE` is "{genre} - {styles}". Nil writes the field's own value.
    public var template: String?
    /// Per format, since YATE writes credits differently in each.
    public var credits: PerTagFormat<CreditStyle>?

    public init(
        join: String? = nil, names: Names? = nil, suffixes: Suffixes? = nil,
        date: DateForm? = nil, template: String? = nil, credits: PerTagFormat<CreditStyle>? = nil
    ) {
        self.join = join
        self.names = names
        self.suffixes = suffixes
        self.date = date
        self.template = template
        self.credits = credits
    }

    /// How a credit is written in `format`.
    public func creditStyle(in format: TagFormat) -> CreditStyle {
        credits?[format] ?? .nameRole
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case join, names, suffixes, date, template, credits
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        join = try container.decodeIfPresent(String.self, forKey: .join)
        names = try container.decodeIfPresent(Names.self, forKey: .names)
        suffixes = try container.decodeIfPresent(Suffixes.self, forKey: .suffixes)
        date = try container.decodeIfPresent(DateForm.self, forKey: .date)
        template = try container.decodeIfPresent(String.self, forKey: .template)
        credits = try container.decodeIfPresent(
            PerTagFormat<CreditStyle>.self, forKey: .credits)
    }
}
