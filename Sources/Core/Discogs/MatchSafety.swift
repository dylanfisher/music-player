/// How little review a Likely album's match needs before Apply to All writes it (ADRs 0170 and
/// 0174). It reads what the matcher kept and changes nothing it decides.
public enum MatchSafety: Equatable, Sendable {
    /// The release fits every file's title in order, the count and every known length, and is
    /// tied, if at all, only with releases of its own title. Titles that say little need
    /// every file's length known.
    case safe
    /// The same, but some lengths differ: at least `titlesFitFiles` files, nearly all of their
    /// titles distinctive, and at least half the known lengths agreeing.
    case titlesFit

    /// The safety of a match at `tier` with `reasons`, from `score`, the chosen release's as
    /// the window shows it, and `distinct`, the share of the album's titles that are
    /// distinctive; nil for a match that needs review.
    static func of(
        _ tier: MatchTier, reasons: [NotExactReason], score: ReleaseScore?, distinct: Double,
        tiedAcrossTitles: Bool
    ) -> MatchSafety? {
        guard tier == .likely, !reasons.isEmpty, let score, !tiedAcrossTitles else { return nil }
        let files = score.mapping.count
        if reasons.allSatisfy(safeReasons.contains) {
            return distinct >= safeDistinct || score.durationsCompared == files ? .safe : nil
        }
        guard reasons.contains(where: \.isDurationsDiffer),
            reasons.allSatisfy({ safeReasons.contains($0) || $0.isDurationsDiffer }),
            files >= titlesFitFiles, distinct >= titlesFitDistinct,
            2 * score.durationsAgreeing >= score.durationsCompared
        else { return nil }
        return .titlesFit
    }

    /// The share of distinctive titles a Safe album needs when some of its lengths aren't
    /// known, and the share a Titles Fit album needs.
    static let safeDistinct = 0.5
    static let titlesFitDistinct = 0.75
    /// The fewest files a Titles Fit album has: a single's titles prove less.
    static let titlesFitFiles = 3

    /// The reasons a Safe album may have: other releases fitting as well, and being found by
    /// title. By the matcher's rules every Likely album has a reason, and one other than these
    /// only when a title, the count, the order or a length doesn't fit.
    private static let safeReasons: [NotExactReason] = [.tiedAfterTieBreak, .foundByTitleOnly]
}

extension NotExactReason {
    /// Whether this is `durationsDiffer`, of any count.
    var isDurationsDiffer: Bool {
        if case .durationsDiffer = self { true } else { false }
    }
}
