/// The library's kinds a search names, by the case's name or its short name: the palette's
/// and the web remote's search fields share them (ADR 0161, 0220).
public enum SearchKind: String, QueryKind, Sendable {
    case playlist, genre, artist, album, track

    /// The short word a query may name the kind by instead.
    public var shortName: String {
        switch self {
        case .album: "a"
        case .artist: "ar"
        case .track: "t"
        case .playlist: "p"
        case .genre: "g"
        }
    }

    public var queryNames: [String] { [rawValue, shortName] }
}
