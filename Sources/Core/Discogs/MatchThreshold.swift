/// The matcher's thresholds, each defined once here and tuned on the owner's matched albums
/// with their release ids hidden (ADR 0131).
enum MatchThreshold {
    /// How alike two folded titles must be, from 0 to 1, to count as the same track's.
    static let sameTitle = 0.85
    /// The similarity a title contained in the other one counts as, when the shorter has at
    /// least `containedLetters`: "Track" against "Track Original Mix".
    static let containedTitle = 0.9
    static let containedLetters = 3
    /// The least similarity at which the alignment pairs a file with a track, when the album
    /// and the release have different counts.
    static let pairedTitle = 0.5
    /// The tracklist score, from 0 to 1, a release of the album's count needs to be Likely.
    static let likelyTracklist = 0.6
    /// A file's length agrees with Discogs's within this many seconds, or this fraction of
    /// Discogs's, whichever is more.
    static let durationSeconds = 8.0
    static let durationFraction = 0.05
    /// How much the share of agreeing durations counts beside the titles when candidates
    /// are ranked. A release without durations counts half.
    static let durationWeight = 0.25
    /// Ranks closer than this are equal.
    static let tie = 1e-9
}
