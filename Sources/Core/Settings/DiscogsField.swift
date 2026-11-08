/// What the Discogs tagger can write from a release, as YATE's Release screen lists it, limited
/// to what the local catalog keeps (ADRs 0130, 0132). Release fields are the same for every
/// file of an album; track fields come from the track a file is matched to.
public enum DiscogsField: String, CaseIterable, Codable, Sendable {
    // The release.
    case releaseID, masterID, releaseURL, masterURL
    case album, albumArtist, albumArtistURL
    case label, labelURL, catalogNumber, labelCatalogNumbers, barcode
    case country, date, genres, styles, media, compilation, discCount
    // The track.
    case title, artist, artistList, artistNameVariations, artistURL
    case trackNumber, trackCount, discNumber, position, ordinalPosition, discSubtitle
    case composer, conductor, lyricist, remixer, producer, involvedPeople

    public enum Level: Sendable { case release, track }

    public var level: Level {
        switch self {
        case .releaseID, .masterID, .releaseURL, .masterURL, .album, .albumArtist,
            .albumArtistURL, .label, .labelURL, .catalogNumber, .labelCatalogNumbers, .barcode,
            .country, .date, .genres, .styles, .media, .compilation, .discCount:
            .release
        case .title, .artist, .artistList, .artistNameVariations, .artistURL, .trackNumber,
            .trackCount, .discNumber, .position, .ordinalPosition, .discSubtitle, .composer,
            .conductor, .lyricist, .remixer, .producer, .involvedPeople:
            .track
        }
    }

    /// Whether the field can hold several values, which its rule's `join` puts together, or
    /// a numbered target writes to a key each.
    var isList: Bool {
        switch self {
        case .albumArtistURL, .label, .labelURL, .labelCatalogNumbers, .genres, .styles, .media,
            .artistList, .artistNameVariations, .artistURL, .composer, .conductor, .lyricist,
            .remixer, .producer, .involvedPeople:
            true
        default: false
        }
    }

    /// The token a template names this field's value with: `{styles}`.
    public var token: String { "{\(rawValue)}" }

    /// The token for the release's first genre alone, as the owner's `GENRE` starts with it.
    public static let firstGenreToken = "{genre}"
}
