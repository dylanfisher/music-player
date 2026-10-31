import Settings

/// What the library window narrows the tracks to: the sidebar's source, the browser panes and the
/// search field. Each pane query applies only the parts to its left, so the artist pane lists the
/// selected genre's artists, and the album pane the albums of both.
public struct TrackFilter: Equatable, Sendable {
    /// A watched folder, a playlist or History, or nil for the whole library.
    public var source: BrowserSource?
    public var genre: Int64?
    public var artist: Int64?
    public var album: Int64?
    /// What was typed in the search field. Words match the starts of words in the title, artist,
    /// album, album artist, genre or composer.
    public var search: String

    public init(
        source: BrowserSource? = nil, genre: Int64? = nil, artist: Int64? = nil,
        album: Int64? = nil, search: String = ""
    ) {
        self.source = source
        self.genre = genre
        self.artist = artist
        self.album = album
        self.search = search
    }
}
