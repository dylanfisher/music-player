import Settings

/// What the library window narrows the tracks to: the sidebar's source, the browser's columns and
/// the search field. Each column's query applies only the columns to its left, so the second
/// lists what the first's selection holds, and the third what both hold.
public struct TrackFilter: Equatable, Sendable {
    /// A watched folder, a playlist or History, or nil for the whole library.
    public var source: BrowserSource?
    /// The entry selected in each column by what the column groups by; a column at All has
    /// none.
    public var selections: [BrowserGrouping: BrowserValue]
    /// What was typed in the search field. Words match the starts of words in the title, artist,
    /// album, album artist, genre or composer.
    public var search: String
    /// `library.groupByAlbumArtist`: the Artists column and `artist` name the album artist, and
    /// sorts by Artist or Album keep each album's tracks together.
    public var groupByAlbumArtist: Bool

    public init(
        source: BrowserSource? = nil, genre: Int64? = nil, artist: Int64? = nil,
        album: Int64? = nil, search: String = "", groupByAlbumArtist: Bool = false
    ) {
        self.source = source
        selections = [:]
        self.search = search
        self.groupByAlbumArtist = groupByAlbumArtist
        self.genre = genre
        self.artist = artist
        self.album = album
    }

    /// The selected genre's ID, as the Genres column selects it.
    var genre: Int64? {
        get { id(.genres) }
        set { selections[.genres] = newValue.map(BrowserValue.id) }
    }
    /// The selected artist's ID, as the Artists column selects it.
    var artist: Int64? {
        get { id(.artists) }
        set { selections[.artists] = newValue.map(BrowserValue.id) }
    }
    /// The selected album's ID, as the Albums column selects it.
    var album: Int64? {
        get { id(.albums) }
        set { selections[.albums] = newValue.map(BrowserValue.id) }
    }

    private func id(_ grouping: BrowserGrouping) -> Int64? {
        guard case .id(let id) = selections[grouping] else { return nil }
        return id
    }
}
