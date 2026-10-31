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
}
