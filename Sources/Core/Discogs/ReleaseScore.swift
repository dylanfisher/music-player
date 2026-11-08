/// How well one release's tracklist fits an album's files (ADR 0131).
struct ReleaseScore: Equatable, Sendable {
    var releaseID: Int
    /// The release's tracks as the files would hold them: the flattening that fit best.
    var tracks: [CatalogTrack]
    /// For each of the album's tracks in order, the index in `tracks` it is, or nil.
    var mapping: [Int?]
    /// Whether the album has as many tracks as `tracks`.
    var sameCount: Bool
    /// The paired titles' similarity over the longer of the two lists, from 0 to 1.
    var tracklist: Double
    /// Every file's title is the same as its track's, in order.
    var titlesInOrder: Bool
    /// Paired tracks whose Discogs length is known, and those whose file agrees with it.
    var durationsCompared: Int
    var durationsAgreeing: Int

    var durationsAgree: Bool { durationsAgreeing == durationsCompared }

    /// Same count and every title in order: the releases that fit an album equally, which the
    /// tie-break chooses among.
    var fitsTracklist: Bool { sameCount && titlesInOrder }

    var isLikely: Bool { sameCount && tracklist >= MatchThreshold.likelyTracklist }

    /// What candidates are ordered by, best last: fitting the tracklist, then Likely, then
    /// `rank`.
    var order: (Int, Int, Double) { (fitsTracklist ? 1 : 0, isLikely ? 1 : 0, rank) }

    /// What candidates are ranked by after their tier: the tracklist, then the lengths.
    var rank: Double {
        let lengths =
            durationsCompared == 0 ? 0.5 : Double(durationsAgreeing) / Double(durationsCompared)
        return tracklist + MatchThreshold.durationWeight * lengths
    }

    /// The best of the release's flattenings for `seconds`, the album's tracks' lengths in
    /// order, and `titles`, their similarity to any title.
    static func best(
        _ release: CatalogRelease, seconds: [Double], titles: TitleSimilarity
    ) -> ReleaseScore {
        let scores = ReleaseTracklist.flattenings(release.tracks).map {
            score($0, releaseID: release.id, seconds: seconds, titles: titles)
        }
        return scores.dropFirst().reduce(scores[0]) { best, next in
            next.order > best.order ? next : best
        }
    }

    static func score(
        _ tracks: [CatalogTrack], releaseID: Int, seconds: [Double], titles: TitleSimilarity
    ) -> ReleaseScore {
        let rows = tracks.map { titles.similarities(to: $0.title) }
        let sameCount = tracks.count == seconds.count
        var mapping: [Int?]
        var total = 0.0
        var inOrder = sameCount && !tracks.isEmpty
        if sameCount {
            // Same count: file i is track i, as Exact asks.
            mapping = Array(tracks.indices)
            for (index, row) in rows.enumerated() {
                total += row[index]
                if row[index] < MatchThreshold.sameTitle { inOrder = false }
            }
        } else {
            (mapping, total) = aligned(rows, files: seconds.count)
        }
        var compared = 0
        var agreeing = 0
        for (file, index) in mapping.enumerated() {
            guard let index, let expected = ReleaseTracklist.seconds(tracks[index]) else {
                continue
            }
            compared += 1
            if agrees(seconds[file], expected) { agreeing += 1 }
        }
        let longer = max(tracks.count, seconds.count)
        return ReleaseScore(
            releaseID: releaseID, tracks: tracks, mapping: mapping, sameCount: sameCount,
            tracklist: longer == 0 ? 0 : total / Double(longer), titlesInOrder: inOrder,
            durationsCompared: compared, durationsAgreeing: agreeing)
    }

    /// Whether a file of `seconds` is a Discogs track of `expected` seconds.
    static func agrees(_ seconds: Double, _ expected: Int) -> Bool {
        let expected = Double(expected)
        return abs(seconds - expected)
            <= max(MatchThreshold.durationSeconds, MatchThreshold.durationFraction * expected)
    }

    /// The in-order pairing of files with tracks that has the most similarity, pairing only
    /// titles at least `MatchThreshold.pairedTitle` alike, so a bonus track or a missing one
    /// leaves the rest paired. `rows[track][file]` is their similarity.
    private static func aligned(_ rows: [[Double]], files: Int) -> ([Int?], Double) {
        let tracks = rows.count
        // best[t][f]: the most similarity pairing the first t tracks with the first f files.
        var best = Array(repeating: Array(repeating: 0.0, count: files + 1), count: tracks + 1)
        for t in 0...tracks {
            for f in 0...files where t > 0 && f > 0 {
                var value = max(best[t - 1][f], best[t][f - 1])
                let similarity = rows[t - 1][f - 1]
                if similarity >= MatchThreshold.pairedTitle {
                    value = max(value, best[t - 1][f - 1] + similarity)
                }
                best[t][f] = value
            }
        }
        var mapping = [Int?](repeating: nil, count: files)
        var t = tracks
        var f = files
        while t > 0, f > 0 {
            let similarity = rows[t - 1][f - 1]
            if similarity >= MatchThreshold.pairedTitle,
                best[t][f] == best[t - 1][f - 1] + similarity
            {
                mapping[f - 1] = t - 1
                t -= 1
                f -= 1
            } else if best[t][f] == best[t - 1][f] {
                t -= 1
            } else {
                f -= 1
            }
        }
        return (mapping, best[tracks][files])
    }
}
