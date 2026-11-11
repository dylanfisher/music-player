import Metadata
import StrictKeys

/// How a Discogs field's value is turned into text (ADR 0132). Every part is optional in JSON;
/// one left out takes the first case named below.
public struct DiscogsFieldFormat: Codable, Equatable, Sendable {
    /// Which of an artist's names is written.
    public enum Names: String, Codable, CaseIterable, Sendable {
        /// The artist's name on Discogs.
        case canonical
        /// The name as the release prints it (its ANV), where it has one.
        case variation
    }

    /// Whether Discogs's number after a name shared by several artists, as in "Artist (2)", is
    /// kept.
    public enum Suffixes: String, Codable, CaseIterable, Sendable {
        case keep, drop
    }

    /// Whether a label Discogs lists more than once, once for each of its catalog numbers, is
    /// written each time, as YATE writes "Columbia & Columbia" (ADR 0128).
    public enum Repeats: String, Codable, CaseIterable, Sendable {
        case keep, drop
    }

    public enum DateForm: String, Codable, CaseIterable, Sendable {
        /// As Discogs writes it: "1999", "1999-03-00" or "1999-03-15".
        case full
        case year
    }

    /// How a credit is written as one value.
    public enum CreditStyle: String, Codable, CaseIterable, Sendable {
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
    /// Nil drops them.
    public var repeats: Repeats?
    public var date: DateForm?
    /// Text with fields' tokens in braces, each replaced by that field's value in this format:
    /// the owner's `GENRE` is "{genre} - {styles}". Nil writes the field's own value.
    public var template: String?
    /// Per format, since YATE writes credits differently in each.
    public var credits: PerTagFormat<CreditStyle>?

    public init(
        join: String? = nil, names: Names? = nil, suffixes: Suffixes? = nil,
        repeats: Repeats? = nil, date: DateForm? = nil, template: String? = nil,
        credits: PerTagFormat<CreditStyle>? = nil
    ) {
        self.join = join
        self.names = names
        self.suffixes = suffixes
        self.repeats = repeats
        self.date = date
        self.template = template
        self.credits = credits
    }

    /// The names written: `names`, or the canonical ones when it's left out.
    public var namesWritten: Names { names ?? .canonical }
    /// Whether the "(2)" is kept: `suffixes`, or kept when it's left out.
    public var suffixesWritten: Suffixes { suffixes ?? .keep }
    /// Whether a repeated label is written again: `repeats`, or dropped when it's left out.
    public var repeatsWritten: Repeats { repeats ?? .drop }
    /// How the date is written: `date`, or in full when it's left out.
    public var dateWritten: DateForm { date ?? .full }
    /// How credits are written in each format: `credits`, or "Name (Role)" in every format
    /// when it's left out.
    public var creditsWritten: PerTagFormat<CreditStyle> { credits ?? PerTagFormat(.nameRole) }

    /// How a credit is written in `format`.
    public func creditStyle(in format: TagFormat) -> CreditStyle { creditsWritten[format] }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case join, names, suffixes, repeats, date, template, credits
    }

    public init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        join = try container.decodeIfPresent(String.self, forKey: .join)
        names = try container.decodeIfPresent(Names.self, forKey: .names)
        suffixes = try container.decodeIfPresent(Suffixes.self, forKey: .suffixes)
        repeats = try container.decodeIfPresent(Repeats.self, forKey: .repeats)
        date = try container.decodeIfPresent(DateForm.self, forKey: .date)
        template = try container.decodeIfPresent(String.self, forKey: .template)
        credits = try container.decodeIfPresent(
            PerTagFormat<CreditStyle>.self, forKey: .credits)
    }
}
