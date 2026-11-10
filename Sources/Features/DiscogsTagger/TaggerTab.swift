import Discogs

/// A tab of the tagger's window: a tier's albums, or Safe and Titles Fit, the Likely albums
/// `MatchSafety` finds need the least review before Apply to All (ADRs 0170 and 0174). Both are
/// views of Likely, which lists their albums too.
enum TaggerTab: CaseIterable, Equatable {
    case exact, likely, safe, titlesFit, incomplete, noCandidate, matched

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
        case .titlesFit: match.safety == .titlesFit
        default: TaggerTab(match.tier) == self
        }
    }
}
