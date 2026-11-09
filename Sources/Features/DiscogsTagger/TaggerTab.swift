import Discogs

/// A tab of the tagger's window: a tier's albums, or Safe, the Likely albums whose release
/// fits every file's title in order, the count and every known length, which Apply to All
/// can write with the least review (ADR 0170). Safe is a view of Likely, which lists them
/// too.
enum TaggerTab: CaseIterable, Equatable {
    case exact, likely, safe, incomplete, noCandidate, matched

    /// The tab of `tier`'s albums.
    init(_ tier: MatchTier) {
        self =
            switch tier {
            case .exact: .exact
            case .likely: .likely
            case .incomplete: .incomplete
            case .noCandidate: .noCandidate
            case .matched: .matched
            }
    }

    /// Whether the tab lists an album matched as `match`.
    func lists(_ match: AlbumMatch) -> Bool {
        switch self {
        case .safe:
            match.tier == .likely && !match.reasons.isEmpty
                && match.reasons.allSatisfy(Self.safeReasons.contains)
        default: TaggerTab(match.tier) == self
        }
    }

    /// The reasons a Safe album may have: other releases fitting as well, and being found by
    /// title. By the matcher's rules every Likely album has a reason, and one other than these
    /// only when a title, the count, the order or a length doesn't fit.
    private static let safeReasons: [NotExactReason] = [.tiedAfterTieBreak, .foundByTitleOnly]
}
