/// One row of a browser pane: a genre, an artist or an album.
public struct BrowserEntry: Equatable, Sendable {
    public var id: Int64
    public var name: String
    /// An album's artist, which tells same-titled albums apart. Nil for a genre, an artist and
    /// a compilation without one.
    public var artist: String?

    public init(id: Int64, name: String, artist: String? = nil) {
        self.id = id
        self.name = name
        self.artist = artist
    }
}
