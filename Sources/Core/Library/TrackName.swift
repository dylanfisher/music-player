/// A track's names, for lists that search or jump by them rather than showing every column.
public struct TrackName: Equatable, Sendable {
    public var id: Int64
    /// The title tag, or the file name without its extension.
    public var title: String
    public var artist: String?
    /// The artist the Artist column sorts by: the album artist grouping of ADR 0031 when the
    /// list groups by album artist, else the track artist.
    public var sortArtist: String?
    public var album: String?
    public var genre: String?
}
