import Foundation
import Library

/// Matches each of `albums` with the catalog at `catalog` (ADR 0131), off the calling thread,
/// in their order. The catalog is opened for this call, so one after an import reads the new
/// file. Cancelling the task stops it before the next album and throws `CancellationError`.
/// `progress` hears each album done, off the main thread.
public func matchAlbums(
    _ albums: [DiscogsAlbum], catalogAt catalog: URL,
    progress: @escaping @Sendable (AlbumMatchProgress) -> Void
) async throws -> [AlbumMatch] {
    try Task.checkCancellation()
    let task = Task.detached(priority: .utility) {
        let matcher = AlbumMatcher(try Catalog(at: catalog))
        var matches: [AlbumMatch] = []
        matches.reserveCapacity(albums.count)
        for album in albums {
            try Task.checkCancellation()
            matches.append(try matcher.match(album))
            progress(AlbumMatchProgress(albumsDone: matches.count, albumCount: albums.count))
        }
        return matches
    }
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}

/// Matches albums with one catalog, on one thread, as its connection is.
final class AlbumMatcher {
    let catalog: Catalog

    init(_ catalog: Catalog) { self.catalog = catalog }

    func match(_ album: DiscogsAlbum) throws -> AlbumMatch {
        let ids = album.tracks.map(\.releaseID)
        let tagged = Set(ids.compactMap { $0 })
        let isMatched = tagged.count == 1 && !ids.contains(nil)
        let titles = TitleSimilarity(album.tracks.map(\.title))
        let seconds = album.tracks.map(\.seconds)
        var releases: [Int: CatalogRelease] = [:]
        var scores: [ReleaseScore] = []
        for id in try candidateIDs(for: album, in: catalog) {
            guard let release = try catalog.release(id: id) else { continue }
            releases[id] = release
            scores.append(ReleaseScore.best(release, seconds: seconds, titles: titles))
        }

        let tier: MatchTier
        let chosen: ReleaseScore?
        if isMatched {
            tier = .matched
            chosen = scores.first { String($0.releaseID) == tagged.first }
        } else if scores.isEmpty {
            (tier, chosen) = (.noCandidate, nil)
        } else {
            let (best, tied) = choose(scores, releases: releases, album: album)
            chosen = best
            if !tagged.isEmpty {
                tier = .incomplete
            } else if best.isExact {
                tier = tied ? .likely : .exact
            } else {
                tier = best.isLikely ? .likely : .incomplete
            }
        }

        var mapping: [Int64: Int] = [:]
        if let chosen {
            for (track, index) in zip(album.tracks, chosen.mapping) {
                if let index { mapping[track.fileID] = index }
            }
        }
        let others = scores.filter { $0.releaseID != chosen?.releaseID }
            .enumerated().sorted { a, b in
                a.element.order != b.element.order
                    ? a.element.order > b.element.order : a.offset < b.offset
            }
            .map { MatchCandidate(releaseID: $0.element.releaseID, score: $0.element) }
        return AlbumMatch(
            albumID: album.id, tier: tier, release: chosen.flatMap { releases[$0.releaseID] },
            tracks: chosen?.tracks ?? [], mapping: mapping, candidates: others)
    }

    /// The best of `scores`, and whether others were as good after the tie-break. The best are
    /// every Exact one when any is, else those ranked highest; among them the tie-break picks,
    /// and the first found of those it leaves.
    private func choose(
        _ scores: [ReleaseScore], releases: [Int: CatalogRelease], album: DiscogsAlbum
    ) -> (ReleaseScore, tied: Bool) {
        let best: [ReleaseScore]
        if scores.contains(where: \.isExact) {
            best = scores.filter(\.isExact)
        } else {
            let top = scores.map(\.order).max { $0 < $1 }!
            best = scores.filter { score in
                score.order.1 == top.1 && top.2 - score.rank <= MatchThreshold.tie
            }
        }
        let left = Set(tieBreak(best.compactMap { releases[$0.releaseID] }, album: album).map(\.id))
        let winner = best.first { left.contains($0.releaseID) }!
        return (winner, left.count > 1)
    }
}
