/// The tags a search's words must all be in, when the search names one kind, as the web
/// remote's `a:dream` does (ADR 0220).
public enum SearchField: Sendable {
    case title, artist, album

    /// The `track_search` columns, as an FTS5 column filter names them.
    var columns: String {
        switch self {
        case .title: "title"
        case .artist: "artist album_artist"
        case .album: "album"
        }
    }
}
