import Settings

/// The tagger window's choices beside Field Mapping… (51.23, ADR 0132), and the artwork the
/// Field Mapping sheet sets (ADR 0140), each kept as a setting so it lasts.
public struct TaggerChoices: Equatable, Sendable {
    /// The kept fields fill only empty tags, whatever the mapping says.
    public var keepExistingValues: Bool
    /// Releases that are only Blu-ray, DVD or video are never candidates.
    public var skipVideo: Bool
    /// `ARTISTSORT` gets the album artist where a file has none.
    public var fillSortArtist: Bool
    /// Whether the release's cover is written, with a token.
    public var artwork: DiscogsArtworkMode

    public init(
        keepExistingValues: Bool, skipVideo: Bool, fillSortArtist: Bool,
        artwork: DiscogsArtworkMode = .off
    ) {
        self.keepExistingValues = keepExistingValues
        self.skipVideo = skipVideo
        self.fillSortArtist = fillSortArtist
        self.artwork = artwork
    }
}
