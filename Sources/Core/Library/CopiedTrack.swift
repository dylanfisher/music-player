/// A track Edit ▸ Copy took: its file, for a paste, and the names its line of text shows. The
/// pasteboard gets the text only, never the file, so nothing pasted elsewhere copies or moves
/// a library file (ADR 0161).
public struct CopiedTrack: Equatable, Sendable {
    public var path: String
    public var artist: String?
    public var title: String

    public init(path: String, artist: String?, title: String) {
        self.path = path
        self.artist = artist
        self.title = title
    }

    public init(_ row: TrackRow) {
        self.init(path: row.path, artist: row.artist, title: row.title)
    }

    /// "Artist – Title", or the title alone for a track without an artist.
    public var line: String {
        guard let artist, !artist.isEmpty else { return title }
        return "\(artist) – \(title)"
    }

    /// One line for each track, in order.
    public static func text(_ tracks: [CopiedTrack]) -> String {
        tracks.map(\.line).joined(separator: "\n")
    }
}
