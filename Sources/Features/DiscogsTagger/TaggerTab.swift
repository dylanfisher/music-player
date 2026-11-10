import Discogs

/// A tab of the tagger's window: a tier's albums, or Safe, the Likely albums `MatchSafety`
/// finds need the least review before Apply to All (ADR 0170). Safe is a view of Likely, which
/// lists them too.
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
        case .safe: match.safety == .safe
        default: TaggerTab(match.tier) == self
        }
    }
}
