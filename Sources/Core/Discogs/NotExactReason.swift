/// Why a Likely or Incomplete album isn't Exact, from what the matcher kept of the chosen
/// release's score and how it was found; nothing is scored again (ADR 0136).
public enum NotExactReason: Equatable, Sendable {
    /// Files the release has no track for, with another count.
    case filesWithoutTrack(Int)
    /// The release's tracks no file is, with another count.
    case tracksWithoutFile(Int)
    /// The album's file count and the release's track count.
    case countDiffers(files: Int, tracks: Int)
    /// With the same count, the files mapped to a track other than their place's, by title.
    case outOfOrder(Int)
    /// With the same count, the files whose title isn't their track's.
    case titlesDiffer(Int)
    /// Files whose length isn't their track's within the tolerance the matcher used: this many
    /// seconds or this fraction of Discogs's length, whichever is more.
    case durationsDiffer(Int, overSeconds: Double, orFraction: Double)
    /// Its tracks carry different release ids, or only some carry one.
    case releaseIDsDiffer
    /// Other releases fit as well, even after the tie-break.
    case tiedAfterTieBreak
    /// Found by artist and title only: no release id, barcode or catalog number led to it.
    case foundByTitleOnly
    /// Found by artist alone, among the artist's releases, when no title search found one
    /// that fits (ADR 0174).
    case foundByArtistOnly

    /// The reasons for `score`, the chosen release's, at `tier`; none for a tier other than
    /// Likely or Incomplete.
    static func reasons(
        _ tier: MatchTier, _ score: ReleaseScore?, tied: Bool, foundBy: CandidateKey?,
        mixedIDs: Bool
    ) -> [NotExactReason] {
        guard tier == .likely || tier == .incomplete else { return [] }
        var reasons: [NotExactReason] = []
        if mixedIDs { reasons.append(.releaseIDsDiffer) }
        if let score {
            if !score.sameCount {
                reasons.append(
                    .countDiffers(files: score.mapping.count, tracks: score.tracks.count))
                let mapped = score.mapping.compactMap { $0 }.count
                if score.mapping.count > mapped {
                    reasons.append(.filesWithoutTrack(score.mapping.count - mapped))
                }
                if score.tracks.count > mapped {
                    reasons.append(.tracksWithoutFile(score.tracks.count - mapped))
                }
            }
            if score.outOfOrder > 0 { reasons.append(.outOfOrder(score.outOfOrder)) }
            if score.titlesDiffering > 0 { reasons.append(.titlesDiffer(score.titlesDiffering)) }
            let differing = score.durationsCompared - score.durationsAgreeing
            if differing > 0 {
                reasons.append(
                    .durationsDiffer(
                        differing, overSeconds: MatchThreshold.durationSeconds,
                        orFraction: MatchThreshold.durationFraction))
            }
        }
        if tied { reasons.append(.tiedAfterTieBreak) }
        if foundBy == .title { reasons.append(.foundByTitleOnly) }
        if foundBy == .artist { reasons.append(.foundByArtistOnly) }
        return reasons
    }
}
