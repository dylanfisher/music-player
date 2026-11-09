import Metadata
import TagWriter

/// A mapping with a name: a preset the app has, or one the user saved.
public struct NamedDiscogsMapping: SettingValue {
    public var name: String
    public var mapping: DiscogsMapping

    public init(name: String, mapping: DiscogsMapping) {
        self.name = name
        self.mapping = mapping
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case name, mapping
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        mapping = try container.decode(DiscogsMapping.self, forKey: .mapping)
    }

    public static var typeName: String { "a named Discogs field mapping (name, mapping)" }
    public static var kind: SettingKind { .discogsMapping }

    public func problem() -> String? {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return "has no name" }
        guard !DiscogsPreset.all.contains(where: { $0.name == name }) else {
            return "\"\(name)\" is a preset's name"
        }
        return mapping.problem().map { "\"\(name)\": \($0)" }
    }
}

/// The mappings the app has (ADR 0132): "One to one", the default, sends each Discogs field to
/// a tag of its own; "Minimal" writes the release id, label, catalog number and year; "YATE"
/// writes YATE's keys in its spellings per format (ADR 0128). Each sends the styles to `MOOD`.
public enum DiscogsPreset {
    public static let all = [oneToOne, minimal, yate]

    public static let oneToOne = NamedDiscogsMapping(
        name: "One to one", mapping: DiscogsMapping(oneToOneRules).checkedOnce())

    public static let minimal = NamedDiscogsMapping(
        name: "Minimal",
        mapping: DiscogsMapping(
            oneToOneRules.mapValues { DiscogsFieldRule(.off, $0.targets, format: $0.format) }
                .merging(
                    [
                        .releaseID: DiscogsFieldRule(.replace, [.key(DiscogsKey.releaseID)]),
                        .label: DiscogsFieldRule(
                            .replace, [.field(.publisher)], format: labelFormat),
                        .catalogNumber: DiscogsFieldRule(.replace, [.field(.catalogNumber)]),
                        .date: DiscogsFieldRule(
                            .replace, [.field(.date)], format: DiscogsFieldFormat(date: .year)),
                    ], uniquingKeysWith: { _, preset in preset })
        ).checkedOnce())

    public static let yate = NamedDiscogsMapping(
        name: "YATE", mapping: DiscogsMapping(yateRules).checkedOnce())
}

extension DiscogsPreset {
    /// Each field's custom keys in every preset, and in the spellings early builds wrote: the
    /// other spellings of its tags that a field replacing them removes from a file (ADR 0152).
    public static let spellings: [DiscogsField: [DiscogsTarget]] = {
        var spellings = [
            DiscogsField.albumArtistURL: [numbered(DiscogsKey.albumArtistURLUnderscored)]
        ]
        for preset in all {
            for (field, rule) in preset.mapping.rules {
                for target in rule.targets where target.isKey {
                    if !spellings[field, default: []].contains(target) {
                        spellings[field, default: []].append(target)
                    }
                }
            }
        }
        return spellings
    }()
}

/// "A & B", as YATE joins several labels (ADR 0128).
private let labelFormat = DiscogsFieldFormat(join: " & ")
private let listFormat = DiscogsFieldFormat(join: ", ")
private let yateListFormat = DiscogsFieldFormat(join: DiscogsKey.valueSeparator)

private func numbered(_ name: String) -> DiscogsTarget {
    .key(PerTagFormat(name), numbered: PerTagFormat(name))
}

private let oneToOneRules: [DiscogsField: DiscogsFieldRule] = [
    .releaseID: DiscogsFieldRule(.replace, [.key(DiscogsKey.releaseID)]),
    .masterID: DiscogsFieldRule(.replace, [.key(DiscogsKey.masterID)]),
    .releaseURL: DiscogsFieldRule(.replace, [.key(DiscogsKey.releaseURL)]),
    .masterURL: DiscogsFieldRule(.replace, [.key(DiscogsKey.masterURL)]),
    .album: DiscogsFieldRule(.replace, [.field(.album)]),
    .albumArtist: DiscogsFieldRule(.replace, [.field(.albumArtist)]),
    .albumArtistURL: DiscogsFieldRule(.replace, [numbered(DiscogsKey.albumArtistURL)]),
    .label: DiscogsFieldRule(.replace, [.field(.publisher)], format: labelFormat),
    .labelURL: DiscogsFieldRule(.replace, [numbered(DiscogsKey.labelURL)]),
    .catalogNumber: DiscogsFieldRule(.replace, [.field(.catalogNumber)]),
    .labelCatalogNumbers: DiscogsFieldRule(.replace, [numbered(DiscogsKey.catalogNumber)]),
    .barcode: DiscogsFieldRule(.replace, [.field(.barcode)]),
    .country: DiscogsFieldRule(.replace, [.key(DiscogsKey.country)]),
    .date: DiscogsFieldRule(.replace, [.field(.date)]),
    .genres: DiscogsFieldRule(.replace, [.field(.genre)], format: listFormat),
    .styles: DiscogsFieldRule(.replace, [.field(.mood)], format: listFormat),
    .media: DiscogsFieldRule(.replace, [.field(.media)], format: listFormat),
    .compilation: DiscogsFieldRule(.replace, [.field(.compilation)]),
    .discCount: DiscogsFieldRule(.replace, [.field(.discTotal)]),
    .title: DiscogsFieldRule(.replace, [.field(.title)]),
    .artist: DiscogsFieldRule(.replace, [.field(.artist)]),
    .artistList: DiscogsFieldRule(.replace, [.key(DiscogsKey.artistList)], format: yateListFormat),
    .artistNameVariations: DiscogsFieldRule(
        .replace, [.key(DiscogsKey.nameVariationList)], format: yateListFormat),
    .artistURL: DiscogsFieldRule(.replace, [numbered(DiscogsKey.artistURL)]),
    .trackNumber: DiscogsFieldRule(.replace, [.field(.trackNumber)]),
    .trackCount: DiscogsFieldRule(.replace, [.field(.trackTotal)]),
    .discNumber: DiscogsFieldRule(.replace, [.field(.discNumber)]),
    .position: DiscogsFieldRule(.replace, [.key(DiscogsKey.trackNumberText)]),
    .ordinalPosition: DiscogsFieldRule(.replace, [.key(DiscogsKey.ordinalPosition)]),
    .discSubtitle: DiscogsFieldRule(.replace, [.field(.discSubtitle)]),
    .composer: DiscogsFieldRule(.replace, [.field(.composer)], format: listFormat),
    .conductor: DiscogsFieldRule(.replace, [.field(.conductor)], format: listFormat),
    .lyricist: DiscogsFieldRule(.replace, [.field(.lyricist)], format: listFormat),
    .remixer: DiscogsFieldRule(.replace, [.field(.remixer)], format: listFormat),
    .producer: DiscogsFieldRule(.replace, [.key(DiscogsKey.producer)], format: listFormat),
    .involvedPeople: DiscogsFieldRule(
        .replace, [.key(DiscogsKey.involvedPeople)], format: yateListFormat),
]

/// YATE's spelling of a key in MP4 and ID3, title case with spaces, where FLAC's differs.
private func titled(_ vorbis: String, _ titled: String) -> DiscogsTarget {
    .key(PerTagFormat(vorbis: vorbis, mp4: titled, id3: titled))
}

/// A URL key, which YATE writes as a `WXXX` frame in ID3, one per value when `numbered`.
private func url(_ name: String, numbered: Bool = false) -> DiscogsTarget {
    let names = PerTagFormat(vorbis: name, mp4: name, id3: ID3CustomKey.url(name))
    return .key(names, numbered: numbered ? names : nil)
}

/// Canonical names without Discogs's "(2)", joined with its join words, as YATE writes
/// `ARTIST` and `ALBUMARTIST`.
private let artistFormat = DiscogsFieldFormat(names: .canonical, suffixes: .drop)

private let yateRules: [DiscogsField: DiscogsFieldRule] = [
    .releaseID: DiscogsFieldRule(.replace, [.key(DiscogsKey.releaseID)]),
    .masterID: DiscogsFieldRule(.replace, [.key(DiscogsKey.masterID)]),
    .releaseURL: DiscogsFieldRule(.replace, [url(DiscogsKey.releaseURL)]),
    .masterURL: DiscogsFieldRule(.replace, [url(DiscogsKey.masterURL)]),
    .album: DiscogsFieldRule(.replace, [.field(.album)]),
    .albumArtist: DiscogsFieldRule(.replace, [.field(.albumArtist)], format: artistFormat),
    .albumArtistURL: DiscogsFieldRule(
        .replace, [url(DiscogsKey.albumArtistURL, numbered: true)]),
    .label: DiscogsFieldRule(.replace, [.field(.publisher)], format: labelFormat),
    .labelURL: DiscogsFieldRule(.replace, [url(DiscogsKey.labelURL, numbered: true)]),
    .catalogNumber: DiscogsFieldRule(.replace, [.field(.catalogNumber)]),
    .labelCatalogNumbers: DiscogsFieldRule(
        .replace,
        [
            .key(
                PerTagFormat(DiscogsKey.catalogNumber),
                numbered: PerTagFormat(
                    vorbis: DiscogsKey.furtherCatalogNumberVorbis, mp4: DiscogsKey.catalogNumber,
                    id3: DiscogsKey.catalogNumber))
        ]),
    .barcode: DiscogsFieldRule(.replace, [.field(.barcode)]),
    .country: DiscogsFieldRule(
        .replace,
        [
            titled(DiscogsKey.releaseCountryVorbis, DiscogsKey.releaseCountryTitled),
            titled(DiscogsKey.country, DiscogsKey.country.capitalized),
        ]),
    .date: DiscogsFieldRule(.replace, [.field(.date)], format: DiscogsFieldFormat(date: .full)),
    .genres: DiscogsFieldRule(.replace, [.field(.genre)], format: listFormat),
    .styles: DiscogsFieldRule(.replace, [.field(.mood)], format: listFormat),
    .media: DiscogsFieldRule(.replace, [.field(.media)], format: listFormat),
    .compilation: DiscogsFieldRule(.replace, [.field(.compilation)]),
    .discCount: DiscogsFieldRule(.replace, [.field(.discTotal)]),
    .title: DiscogsFieldRule(.replace, [.field(.title)]),
    .artist: DiscogsFieldRule(.replace, [.field(.artist)], format: artistFormat),
    .artistList: DiscogsFieldRule(
        .replace, [.key(DiscogsKey.artistList)],
        format: DiscogsFieldFormat(
            join: DiscogsKey.valueSeparator, names: .canonical, suffixes: .keep)),
    .artistNameVariations: DiscogsFieldRule(
        .replace, [.key(DiscogsKey.nameVariationList)], format: yateListFormat),
    .artistURL: DiscogsFieldRule(.replace, [url(DiscogsKey.artistURL, numbered: true)]),
    .trackNumber: DiscogsFieldRule(.replace, [.field(.trackNumber)]),
    .trackCount: DiscogsFieldRule(.replace, [.field(.trackTotal)]),
    .discNumber: DiscogsFieldRule(.replace, [.field(.discNumber)]),
    .position: DiscogsFieldRule(
        .replace, [titled(DiscogsKey.trackNumberText, DiscogsKey.trackNumberTextTitled)]),
    .ordinalPosition: DiscogsFieldRule(
        .replace, [titled(DiscogsKey.ordinalPosition, DiscogsKey.ordinalPositionTitled)]),
    .discSubtitle: DiscogsFieldRule(.replace, [.field(.discSubtitle)]),
    .composer: DiscogsFieldRule(.replace, [.field(.composer)], format: listFormat),
    .conductor: DiscogsFieldRule(.replace, [.field(.conductor)], format: listFormat),
    .lyricist: DiscogsFieldRule(.replace, [.field(.lyricist)], format: listFormat),
    .remixer: DiscogsFieldRule(.replace, [.field(.remixer)], format: listFormat),
    .producer: DiscogsFieldRule(
        .replace, [.key(DiscogsKey.producer)], format: yateListFormat),
    .involvedPeople: DiscogsFieldRule(
        .replace,
        [
            .key(
                PerTagFormat(
                    vorbis: DiscogsKey.involvedPeople, mp4: DiscogsKey.involvedPeople,
                    id3: ID3CustomKey.involvedPeople))
        ],
        format: DiscogsFieldFormat(
            join: DiscogsKey.valueSeparator,
            credits: PerTagFormat(vorbis: .nameRole, mp4: .roleNames, id3: .roleNames))),
]
