import Library

/// How an album fits the catalog (ADR 0131).
public enum MatchTier: String, CaseIterable, Sendable {
    /// Its tracks' count, titles in order and known lengths fit one release, which won the
    /// tie-break if others fit as well.
    case exact
    /// A release of its count whose tracklist fits above `MatchThreshold.likelyTracklist`, or
    /// an exact fit still tied after the tie-break.
    case likely
    /// The best release has another count or fits only weakly, or the album's tracks carry
    /// different release ids or only some do.
    case incomplete
    case noCandidate
    /// Every track already carries one release id: the chosen release is that one, scored
    /// again for a refresh.
    case matched
}

/// A release an album might be, and how well it fits.
public struct MatchCandidate: Equatable, Sendable {
    public var releaseID: Int
    var score: ReleaseScore

    /// How well its tracklist fits the album's, from 0 to 1 (ADR 0131).
    public var tracklistScore: Double { score.tracklist }
    /// Whether it has the album's track count and every title in order.
    public var fitsTracklist: Bool { score.fitsTracklist }
}

/// What matching found for one album: its tier, the release chosen, how its files map to that
/// release's tracks, and the other candidates.
public struct AlbumMatch: Sendable {
    public internal(set) var albumID: Int64
    public var tier: MatchTier
    /// Nil for no candidate, or for a matched album whose release isn't in the catalog.
    public internal(set) var release: CatalogRelease?
    /// The chosen release's tracks as files hold them (`ReleaseTracklist`).
    var tracks: [CatalogTrack]
    /// Each file's index in `tracks`, by file id; a file that fits no track isn't in it.
    public var mapping: [Int64: Int]
    /// The other releases found, the best first.
    public var candidates: [MatchCandidate]

    public var releaseID: Int? { release?.id }

    /// How many tracks the chosen release has as files hold them.
    public var releaseTrackCount: Int { tracks.count }
}

/// How far a matching run has got.
public struct AlbumMatchProgress: Equatable, Sendable {
    public var albumsDone: Int
    public var albumCount: Int
}
