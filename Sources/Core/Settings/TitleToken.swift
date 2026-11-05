/// A field of the playing track that a `TitleTemplate` names in braces, as `{artist}`.
/// The names are the track table's columns' where they share one.
public enum TitleToken: String, CaseIterable, Sendable {
    case title, artist, album, albumArtist, composer, genre, year, trackNumber, discNumber,
        format

    /// The token as a template writes it.
    var placeholder: String { "{\(rawValue)}" }

    /// What it stands for, as the setting's help lists it.
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
