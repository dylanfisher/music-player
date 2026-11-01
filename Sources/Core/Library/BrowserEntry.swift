/// One row of a browser pane: a genre, an artist or an album.
public struct BrowserEntry: Equatable, Sendable {
    public var id: Int64
    public var name: String
    /// An album's artist, which tells same-titled albums apart. Nil for a genre, an artist and
    /// a compilation without one.
    public var artist: String?

    init(id: Int64, name: String, artist: String? = nil) {
        self.id = id
        self.name = name
        self.artist = artist
    }
}

/// The Album pane's text for `albums`: each title, with its artist beside it wherever another
/// album listed has the same title. A compilation without an album artist is Various Artists'.
public func albumTitles(_ albums: [BrowserEntry]) -> [String] {
    let counts = Dictionary(albums.map { ($0.name, 1) }, uniquingKeysWith: +)
    return albums.map { album in
        counts[album.name, default: 0] > 1
            ? "\(album.name) \u{2014} \(album.artist ?? variousArtists)" : album.name
    }
}
