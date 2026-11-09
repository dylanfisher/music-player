import Metadata
import TagWriter

/// A tag a Discogs field is written to: a field the tag editor knows, the same in every format,
/// or a custom key, spelled per format where YATE spells it so (ADRs 0128, 0129).
public enum DiscogsTarget: Codable, Equatable, Sendable {
    case field(TagEditField)
    /// `numbered`, when set, gives each value of a list its own key: the first goes to `key`,
    /// the second to `numbered` and "-2", and so on, as YATE writes several labels' catalog
    /// numbers and URLs.
    case key(PerTagFormat<String>, numbered: PerTagFormat<String>? = nil)

    /// A custom key spelled the same in every format.
    public static func key(_ name: String) -> DiscogsTarget { .key(PerTagFormat(name)) }

    /// The target `names` and `numbered` spell, as the config file reads a target: a field
    /// when every format spells one field's name and it isn't numbered, else a custom key.
    public init(names: PerTagFormat<String>, numbered: PerTagFormat<String>? = nil) {
        if numbered == nil, names.isUniform,
            let field = TagEditField(rawValue: names.vorbis)
        {
            self = .field(field)
        } else {
            self = .key(names, numbered: numbered)
        }
    }

    /// The tag's name in each format: a field's name in all three, or the key's spellings.
    public var names: PerTagFormat<String> {
        switch self {
        case .field(let field): PerTagFormat(field.rawValue)
        case .key(let names, _): names
        }
    }

    /// The numbered keys' spellings, or nil when the target isn't numbered.
    public var numberedNames: PerTagFormat<String>? {
        if case .key(_, let numbered) = self { numbered } else { nil }
    }

    /// The target as the Field Mapping sheet and Settings ▸ Tagging list it: its name, or each
    /// format's spelling, vorbis, mp4 then id3, where they differ, and "(numbered)" after a
    /// numbered key.
    public var text: String {
        let spelled =
            names.isUniform
            ? names.vorbis : [names.vorbis, names.mp4, names.id3].joined(separator: " / ")
        return spelled + (isNumbered ? " (numbered)" : "")
    }

    /// The key names `numbered` is followed by before a value's number: "DISCOGS_LABEL_URL-2".
    static let numberSeparator = "-"

    /// The tag this writes in `format`.
    public func tag(in format: TagFormat) -> MappedTag {
        switch self {
        case .field(let field): .field(field)
        case .key(let names, _): .custom(names[format])
        }
    }

    /// The key the `index`th value, counted from 0, goes to in `format`: `tag(in:)`'s for the
    /// first, and a numbered key for the rest; nil past the first when the target isn't
    /// numbered.
    public func tag(in format: TagFormat, value index: Int) -> MappedTag? {
        guard index > 0 else { return tag(in: format) }
        guard case .key(_, let numbered?) = self else { return nil }
        return .custom(numbered[format] + Self.numberSeparator + String(index + 1))
    }

    /// Whether this is a custom key rather than a field.
    public var isKey: Bool {
        if case .key = self { true } else { false }
    }

    /// Whether each value of a list gets a key of its own.
    public var isNumbered: Bool {
        if case .key(_, numbered: .some) = self { true } else { false }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case key, numbered
    }

    /// In JSON a target is a string, a field's name when it is one ("genre") and otherwise a
    /// custom key's ("DISCOGS_RELEASE_ID"), or an object for a key spelled per format or
    /// numbered: `{"key": {"vorbis": …, "mp4": …, "id3": …}, "numbered": …}`.
    public init(from decoder: any Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            self = DiscogsTarget(names: PerTagFormat(name))
            return
        }
        try rejectUnknownKeys(decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = .key(
            try container.decode(PerTagFormat<String>.self, forKey: .key),
            numbered: try container.decodeIfPresent(PerTagFormat<String>.self, forKey: .numbered))
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .field(let field):
            var container = encoder.singleValueContainer()
            try container.encode(field.rawValue)
        case .key(let names, nil) where names.isUniform:
            var container = encoder.singleValueContainer()
            try container.encode(names.vorbis)
        case .key(let names, let numbered):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(names, forKey: .key)
            try container.encodeIfPresent(numbered, forKey: .numbered)
        }
    }
}

/// A tag in one file's format: a field the tag editor knows, or a custom key as spelled.
public enum MappedTag: Hashable, Sendable {
    case field(TagEditField)
    case custom(String)

    /// The custom key's name uppercased, as keys are compared, so two spellings of one key
    /// are one tag.
    var comparable: MappedTag {
        if case .custom(let name) = self { .custom(name.uppercased()) } else { self }
    }

    /// As the View Changes sheet names it: the field's name or the key.
    public var name: String {
        switch self {
        case .field(let field): field.rawValue
        case .custom(let name): name
        }
    }
}
