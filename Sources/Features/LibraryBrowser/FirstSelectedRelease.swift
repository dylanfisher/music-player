extension LibraryBrowser {
    /// The Discogs release the first selected track is tagged with, for the track menu's Show
    /// Discography; nil for none, or when nothing is selected.
    public func firstSelectedRelease() throws -> Int? {
        try firstSelectedTrackID().flatMap { try index.discogsReleaseID(ofTrack: $0) }
    }
}
