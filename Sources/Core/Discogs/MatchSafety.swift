/// How little review a Likely album's match needs before Apply to All writes it (ADR 0170):
/// Safe, whose release fits every file's title in order, the count and every known length, and
/// is tied, if at all, only for reasons the owner accepts. It reads what the matcher kept and
/// changes nothing it decides.
public enum MatchSafety: Equatable, Sendable {
    case safe

    /// The safety of a match at `tier` with `reasons`; nil for one that needs review.
    static func of(_ tier: MatchTier, reasons: [NotExactReason]) -> MatchSafety? {
        guard tier == .likely, !reasons.isEmpty else { return nil }
        return reasons.allSatisfy(safeReasons.contains) ? .safe : nil
    }

    /// The reasons a Safe album may have: other releases fitting as well, and being found by
    /// title. By the matcher's rules every Likely album has a reason, and one other than these
    /// only when a title, the count, the order or a length doesn't fit.
    private static let safeReasons: [NotExactReason] = [.tiedAfterTieBreak, .foundByTitleOnly]
}
