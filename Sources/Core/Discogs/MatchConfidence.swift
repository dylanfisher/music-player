/// How sure a match is of its release, from 0 to 100 percent (ADR 0170): the share of title
/// fit, less points for lengths that differ or aren't known, another count, files out of
/// order, a tie, a release found by title only, and tracks carrying different release ids.
/// It reads the chosen release's score and changes nothing the matcher decides.
enum MatchConfidence {
    /// Points off when every file's length differs from its track's; a share of them takes
    /// that share.
    static let durationsDiffering = 30.0
    /// Points off when no file's track has a length on Discogs.
    static let durationsUnknown = 5.0
    static let countDiffers = 10.0
    /// Points off when every file is paired out of its place.
    static let outOfOrder = 10.0
    static let tied = 5.0
    static let foundByTitleOnly = 5.0
    static let releaseIDsDiffer = 10.0

    /// The confidence of `score`, the chosen release's as the window shows it, against the
    /// album's titles. A title at least `MatchThreshold.sameTitle` like its track's counts in
    /// full, as the matcher counts it the same; one below counts its similarity.
    static func percent(
        _ score: ReleaseScore, titles: TitleSimilarity, tied: Bool, foundBy: CandidateKey?,
        mixedIDs: Bool
    ) -> Int {
        let longer = max(score.tracks.count, score.mapping.count)
        guard longer > 0 else { return 0 }
        var fit = 0.0
        var mapped = 0
        for (file, index) in score.mapping.enumerated() {
            guard let index else { continue }
            mapped += 1
            let similarity = titles.similarities(to: score.tracks[index].title)[file]
            fit += similarity >= MatchThreshold.sameTitle ? 1 : similarity
        }
        var points = 100 * fit / Double(longer)
        if mapped > 0 {
            let mappedCount = Double(mapped)
            let differing = score.durationsCompared - score.durationsAgreeing
            points -= durationsDiffering * Double(differing) / mappedCount
            points -= durationsUnknown * Double(mapped - score.durationsCompared) / mappedCount
        }
        if !score.sameCount { points -= countDiffers }
        points -= outOfOrder * Double(score.outOfOrder) / Double(longer)
        if tied { points -= Self.tied }
        if foundBy == .title { points -= foundByTitleOnly }
        if mixedIDs { points -= releaseIDsDiffer }
        return Int(min(100, max(0, points)).rounded())
    }
}
