/// A track's names, for lists that search or jump by them rather than showing every column.
public struct TrackName: Equatable, Sendable {
    public var id: Int64
    /// The title tag, or the file name without its extension.
    public var title: String
    public var artist: String?
    public var album: String?
    public var genre: String?

    public init(id: Int64, title: String, artist: String?, album: String?, genre: String?) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
    }
}
