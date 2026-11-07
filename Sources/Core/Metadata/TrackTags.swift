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
    public var movementTotal: Int?
    public var movementName: String?
    /// As written, like `date`.
    public var originalDate: String?
    public var titleSort: String?
    public var artistSort: String?
    public var albumSort: String?
    public var albumArtistSort: String?
    public var composerSort: String?
    public var remixer: String?
    public var originalArtist: String?
    public var originalAlbum: String?
    public var isrc: String?
    /// As written, usually an ISO 639-2 code such as "eng".
    public var language: String?
    public var mood: String?
    /// The release's medium as written, such as "CD" or "Digital Media".
    public var media: String?
    /// Unsynchronized lyrics, lines separated by newlines.
    public var lyrics: String?
    public var artistURL: String?
    public var audioFileURL: String?
    public var audioSourceURL: String?
    public var commercialURL: String?
    public var copyrightURL: String?
    public var paymentURL: String?
    public var publisherURL: String?
    public var radioStationURL: String?
    /// The keys no field above maps, by name uppercased, as taggers compare them: Vorbis
    /// comment keys, ID3 `TXXX` descriptions and the names of MP4 freeform items whose `mean`
    /// is `com.apple.iTunes` (ADR 0129). The first value of a name wins, as for the fields.
    public var custom: [String: String] = [:]

    /// Whether no field is set, as for a file with no tag.
    package var isEmpty: Bool { self == TrackTags() }
}
