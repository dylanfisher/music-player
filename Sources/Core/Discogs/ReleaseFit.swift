import Library

/// Whether a release could be an album's files at all, whatever else fits better.
public enum ReleaseFit: Equatable, Sendable {
    case fits
    /// The release has another number of tracks than the album, however its index tracks
    /// are counted.
    case otherCount
    /// The counts are the same, but not every title is the same in order.
    case otherTitles
}

/// How `release` fits `album`'s tracks, as the matcher scores it (ADR 0131).
public func releaseFit(_ album: DiscogsAlbum, _ release: CatalogRelease) -> ReleaseFit {
    let score = ReleaseScore.best(
        release, seconds: album.tracks.map(\.seconds),
        titles: TitleSimilarity(album.tracks.map(\.title)))
    if score.fitsTracklist { return .fits }
    return score.sameCount ? .otherTitles : .otherCount
}

/// Whether `album`'s tags name a date or a format `release` doesn't have as written: Discogs
/// has changed the release since the tags were written, by a fuller date or more
/// descriptions or anything else.
public func tagsOutdate(_ album: DiscogsAlbum, _ release: CatalogRelease) -> Bool {
    if let date = album.date, release.released != date { return true }
    if let media = album.media, !release.formats.map(mediaText).contains(media) { return true }
    return false
}
