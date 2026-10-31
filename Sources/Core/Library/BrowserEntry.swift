/// One row of a browser pane: a genre, an artist or an album.
public struct BrowserEntry: Equatable, Sendable {
    public var id: Int64
    public var name: String
}
