/// What `appearance.windowTitle` and the toolbar's Title Line, `appearance.headerTitleFormat`,
/// hold: text filled from the playing track (ADR 0087).
public typealias TitleTemplate = TokenTemplate<TitleToken>

extension TokenTemplate where Token == TitleToken {
    public static var windowTitle: TitleTemplate { TitleTemplate("{title} — {artist}") }
    /// Swinsian's toolbar line: "FI3AC2384210 by Aleksi Perälä from Alithia E'".
    public static var titleLine: TitleTemplate { TitleTemplate("{title} by {artist} from {album}") }
}

/// A field of the playing track that a `TitleTemplate` names in braces, as `{artist}`.
/// The names are the track table's columns' where they share one.
public enum TitleToken: String, TemplateToken {
    case title, artist, album, albumArtist, composer, genre, year, trackNumber, discNumber,
        format

    public static var example: String { TitleTemplate.windowTitle.template }

    public var help: String {
        switch self {
        case .title: "The title, or the file's name when it has no title tag"
        case .artist: "The artist"
        case .album: "The album"
        case .albumArtist: "The album artist"
        case .composer: "The composer"
        case .genre: "The genre"
        case .year: "The year the date tag starts with"
        case .trackNumber: "The track number"
        case .discNumber: "The disc number"
        case .format: "The file's format, such as 96 kHz 24-bit FLAC"
        }
    }
}
