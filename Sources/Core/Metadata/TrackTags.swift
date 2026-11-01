/// The tag fields the library shows and sorts by. When a format holds a field more than once, the
/// first value wins.
public struct TrackTags: Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    /// As written: "1997", "1997-05-12", or whatever the tagger stored.
    public var date: String?
    public var trackNumber: Int?
    public var trackTotal: Int?
    public var discNumber: Int?
    public var discTotal: Int?
    public var compilation = false
    public var composer: String?
    public var comment: String?
    public var grouping: String?
    public var catalogNumber: String?
    public var barcode: String?
    /// Beats per minute, rounded to a whole number.
    public var bpm: Int?
    /// The musical key as written, such as "Am" or "8A".
    public var key: String?
    public var conductor: String?
    public var lyricist: String?
    /// The record label.
    public var publisher: String?
    public var copyright: String?
    /// Who or what encoded the file, as the tagger stored it.
    public var encoder: String?
    public var description: String?
    public var discSubtitle: String?
    public var work: String?
    public var movementNumber: Int?
    public var movementName: String?
    /// As written, like `date`.
    public var originalDate: String?
}
