/// The tagger window's choices beside Field Mapping… (51.23, ADR 0132), each kept as a
/// setting so it lasts.
public struct TaggerChoices: Equatable, Sendable {
    /// The kept fields fill only empty tags, whatever the mapping says.
    public var keepExistingValues: Bool
    /// Releases that are only Blu-ray, DVD or video are never candidates.
    public var skipVideo: Bool
    /// `ARTISTSORT` gets the album artist where a file has none.
    public var fillSortArtist: Bool

    public init(keepExistingValues: Bool, skipVideo: Bool, fillSortArtist: Bool) {
        self.keepExistingValues = keepExistingValues
        self.skipVideo = skipVideo
        self.fillSortArtist = fillSortArtist
    }
}
