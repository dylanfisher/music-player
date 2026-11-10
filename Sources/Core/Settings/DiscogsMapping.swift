import Metadata
import TagWriter

/// Where the Discogs tagger writes each field, set once and used for every album (ADR 0132).
/// In JSON an object with a rule for every field, by the field's name; a field left out is a
/// problem, so a misspelled one isn't silently off.
public struct DiscogsMapping: SettingValue {
    public var rules: [DiscogsField: DiscogsFieldRule] {
        didSet { checked = nil }
    }
    /// `problem()`'s answer for these rules, once worked out: the schema checks its default
    /// each time it's made, which the app does often, and the check reads every key.
    private var checked: Checked?

    private struct Checked { var problem: String? }

    public init(_ rules: [DiscogsField: DiscogsFieldRule]) {
        self.rules = rules
    }

    /// This mapping with `problem()` worked out, for a preset the schema checks often.
    func checkedOnce() -> DiscogsMapping {
        var mapping = self
        mapping.checked = Checked(problem: findProblem())
        return mapping
    }

    public static func == (a: DiscogsMapping, b: DiscogsMapping) -> Bool { a.rules == b.rules }

    public subscript(field: DiscogsField) -> DiscogsFieldRule {
        get {
            guard let rule = rules[field] else { preconditionFailure("\(field) has no rule") }
            return rule
        }
        set { rules[field] = newValue }
    }

    /// The fields a user's own tags often hold better than Discogs: "Keep existing values" in
    /// the tagger fills only their empty tags (51.23).
    static let keptFields: [DiscogsField] = [
        .title, .artist, .albumArtist, .trackNumber, .trackCount, .discNumber, .discCount,
        .composer, .conductor, .lyricist, .remixer, .date,
    ]

    /// This mapping with each of `keptFields` that replaces its tags filling only empty ones.
    public func keepingExistingValues() -> DiscogsMapping {
        var mapping = self
        for field in Self.keptFields where mapping[field].mode == .replace {
            mapping[field].mode = .fillEmpty
        }
        return mapping
    }

    /// This mapping with the album title, when `titles` is set, and the album artist, when
    /// `artists` is, replacing the tag the library groups albums by, whatever their mode: the
    /// albums combined for tagging become one album only when their files agree on both
    /// (ADR 0179).
    public func combining(titles: Bool, artists: Bool) -> DiscogsMapping {
        var mapping = self
        let forced: [(DiscogsField, TagEditField)] =
            (titles ? [(.album, .album)] : []) + (artists ? [(.albumArtist, .albumArtist)] : [])
        for (field, tag) in forced {
            mapping[field].mode = .replace
            if !mapping[field].targets.contains(.field(tag)) {
                mapping[field].targets.append(.field(tag))
            }
        }
        return mapping
    }

    /// This mapping with every field that fills only empty tags replacing them instead: a
    /// staged download's tags are its uploader's, so none is kept over the release's (ADR 0146).
    public func overwriting() -> DiscogsMapping {
        var mapping = self
        for field in DiscogsField.allCases where mapping[field].mode == .fillEmpty {
            mapping[field].mode = .replace
        }
        return mapping
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: FieldKey.self)
        var rules: [DiscogsField: DiscogsFieldRule] = [:]
        for key in container.allKeys {
            guard let field = DiscogsField(rawValue: key.stringValue) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: container, debugDescription: "isn't a Discogs field")
            }
            rules[field] = try container.decode(DiscogsFieldRule.self, forKey: key)
        }
        self.rules = rules
    }

    private struct FieldKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(
            Dictionary(uniqueKeysWithValues: rules.map { ($0.key.rawValue, $0.value) }))
    }

    public static var typeName: String { "a Discogs field mapping" }
    public static var kind: SettingKind { .discogsMapping }

    /// A rule the writer couldn't follow: a field without one, a list without a join, a
    /// template naming no field, a key no format can hold or one only ID3 has spelled for
    /// another format, or two fields writing one tag.
    public func problem() -> String? { checked.map(\.problem) ?? findProblem() }

    private func findProblem() -> String? {
        var written: [TagFormat: [MappedTag: DiscogsField]] = [:]
        for field in DiscogsField.allCases {
            guard let rule = rules[field] else { return "no rule for \(field.rawValue)" }
            guard rule.mode != .off else { continue }
            guard !rule.targets.isEmpty else { return "\(field.rawValue) is on with no target" }
            let joinsArtists = field == .artist || field == .albumArtist
            if field.isList, !joinsArtists, rule.format.join == nil,
                !rule.targets.allSatisfy(\.isNumbered)
            {
                return "\(field.rawValue) is a list, so it needs a join"
            }
            if let template = rule.format.template,
                let token = templateTokens(template).first(where: { !templateNameSet.contains($0) })
            {
                return "\(field.rawValue)'s template names \(token), which isn't a field"
            }
            for target in rule.targets {
                if let problem = keyProblem(target) { return "\(field.rawValue): \(problem)" }
                for format in TagFormat.allCases {
                    let tag = target.tag(in: format).comparable
                    if let other = written[format, default: [:]][tag] {
                        return "\(other.rawValue) and \(field.rawValue) both write"
                            + " \(target.tag(in: format).name) in \(format.rawValue)"
                    }
                    written[format, default: [:]][tag] = field
                }
            }
        }
        return nil
    }
}

/// Why a target's custom key can't be written in some format, or nil.
private func keyProblem(_ target: DiscogsTarget) -> String? {
    guard case .key(let names, let numbered) = target else { return nil }
    for format in TagFormat.allCases {
        for name in [names[format], numbered.map { $0[format] }].compactMap(\.self) {
            if format != .id3, ID3CustomKey.isID3Only(name) {
                return "\(name) is an ID3 frame, which \(format.rawValue) doesn't hold"
            }
        }
    }
    let spellings =
        [names.vorbis, names.mp4, names.id3]
        + [numbered?.vorbis, numbered?.mp4, numbered?.id3].compactMap(\.self)
    for name in Set(spellings) {
        if fieldNames.contains(name) {
            return "\(name) is a field's name, so it would read back as that field"
        }
        if let problem = customKeyProblem(name) { return "\(name) \(problem)" }
    }
    return nil
}

extension DiscogsMapping {
    /// The tokens a template can name, in field order, then the first genre's: what the check
    /// accepts, and what Field Mapping's help lists.
    public static let templateNames =
        DiscogsField.allCases.map(\.token) + [DiscogsField.firstGenreToken]
}

private let templateNameSet = Set(DiscogsMapping.templateNames)

/// The names a target in JSON reads as a field by.
private let fieldNames = Set(TagEditField.allCases.map(\.rawValue))

/// The `{…}` tokens in `template`, braces included, in order.
func templateTokens(_ template: String) -> [String] {
    var tokens: [String] = []
    var rest = Substring(template)
    while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
        tokens.append(String(rest[open...close]))
        rest = rest[rest.index(after: close)...]
    }
    return tokens
}
