import Foundation
import Library
import Settings

/// Matches each of `albums` with the catalog at `catalog`, the Discogs API or both, as `source`
/// says (ADRs 0131 and 0139), off the calling thread, in their order. The catalog is opened for
/// this call, so one after an import reads the new file; with `.api` it isn't opened at all.
/// Cancelling the task stops it before the next album, or during a wait for Discogs's rate
/// limit, and throws `CancellationError`. A `DiscogsAPIError` that stops the run is thrown;
/// in Both, as `APIStoppedMatching`, with the matches made.
/// `progress` hears each album done and each long wait, off the main thread. `chosen` holds
/// the release the user chose for an album, by album ID, which is its match whatever the
/// others score (ADR 0133). `skippingVideo` leaves out the releases that are only Blu-ray, DVD
/// or video (ADR 0132). `api` is required for `.api` and `.both`.
public func matchAlbums(
    _ albums: [DiscogsAlbum], catalogAt catalog: URL, source: DiscogsSource = .catalog,
    api: DiscogsAPI? = nil, choosing chosen: [Int64: Int], skippingVideo: Bool,
    progress: @escaping @Sendable (AlbumMatchProgress) -> Void
) async throws -> [AlbumMatch] {
    try Task.checkCancellation()
    guard source == .catalog || api != nil else {
        preconditionFailure("matching with \(source) needs the Discogs API")
    }
    let task = Task.detached(priority: .utility) {
        let matcher = AlbumMatcher(
            source == .api ? nil : try Catalog(at: catalog), skippingVideo: skippingVideo)
        let reporter = ProgressReporter(progress)
        var matches: [AlbumMatch] = []
        matches.reserveCapacity(albums.count)
        if source != .api {
            for album in albums {
                try Task.checkCancellation()
                matches.append(try matcher.match(album, choosing: chosen[album.id]))
                if isReported(matches.count, of: albums.count) {
                    reporter.report(albumsDone: matches.count, albumCount: albums.count)
                }
            }
        }
        guard let api, source != .catalog else { return matches }
        let indices =
            source == .api
            ? Array(albums.indices)
            : albums.indices.filter { needsAPI(matches[$0], choosing: chosen[albums[$0].id]) }
        // The run's waits go to its own progress; a run within it, as choosing a release is,
        // gives them back when it ends.
        let previous = await api.setWaiting { reporter.waiting($0) }
        do {
            var done = 0
            for index in indices {
                try Task.checkCancellation()
                let album = albums[index]
                let match = try await matchWithAPI(
                    album, choosing: chosen[album.id], matcher: matcher, api: api)
                if source == .api { matches.append(match) } else { matches[index] = match }
                done += 1
                if source == .api {
                    reporter.report(albumsDone: done, albumCount: indices.count)
                } else {
                    reporter.report(
                        albumsDone: albums.count, albumCount: albums.count, apiAlbumsDone: done,
                        apiAlbumCount: indices.count)
                }
            }
        } catch {
            await api.setWaiting(previous)
            // Both keeps what the catalog matched, with the albums the API did before it stopped.
            if source == .both, let error = error as? DiscogsAPIError, error != .cancelled {
                throw APIStoppedMatching(matches: matches, error: error)
            }
            throw error
        }
        await api.setWaiting(previous)
        return matches

    }
    return try await withTaskCancellationHandler {
        do {
            return try await task.value
        } catch DiscogsAPIError.cancelled {
            throw CancellationError()
        }
    } onCancel: {
        task.cancel()
    }
}

/// A Both run whose API pass stopped, as for no connection or a refused token: every album
/// matched as the catalog pass and the API pass so far had it, and why the API stopped. Only
/// the API alone loses its run to such an error (ADR 0139).
public struct APIStoppedMatching: Error, CustomStringConvertible {
    public var matches: [AlbumMatch]
    public var error: DiscogsAPIError

    public var description: String { error.description }
}

/// Whether Both asks the API about an album the catalog pass matched as `match`: one with no
/// candidate, one whose tracks carry a release id the catalog lacks, and one whose chosen
/// release it lacks. The dump has no date for each release, so "newer than the dump" is
/// "not in the catalog" (ADR 0139).
func needsAPI(_ match: AlbumMatch, choosing choice: Int?) -> Bool {
    match.tier == .noCandidate || (match.tier == .matched && match.release == nil)
        || (choice != nil && match.releaseID != choice)
}

/// `album` matched again with what the API finds for it beside the catalog's candidates. Only
/// the releases the catalog lacks are fetched.
private func matchWithAPI(
    _ album: DiscogsAlbum, choosing choice: Int?, matcher: AlbumMatcher, api: DiscogsAPI
) async throws -> AlbumMatch {
    let found = try await ApiCandidates.found(for: album, choosing: choice, api: api)
    var missing: [Int] = []
    for candidate in found where try matcher.catalog?.release(id: candidate.id) == nil {
        missing.append(candidate.id)
    }
    let fetched = try await ApiCandidates.fetch(missing, api: api)
    return try matcher.match(album, choosing: choice, found: found, fetched: fetched)
}

/// Sends a run's progress from any thread, with the rate-limit wait the API reports.
private final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var last = AlbumMatchProgress(albumsDone: 0, albumCount: 0)
    private let progress: @Sendable (AlbumMatchProgress) -> Void

    init(_ progress: @escaping @Sendable (AlbumMatchProgress) -> Void) {
        self.progress = progress
    }

    func report(
        albumsDone: Int, albumCount: Int, apiAlbumsDone: Int? = nil, apiAlbumCount: Int? = nil
    ) {
        let next = AlbumMatchProgress(
            albumsDone: albumsDone, albumCount: albumCount, apiAlbumsDone: apiAlbumsDone,
            apiAlbumCount: apiAlbumCount)
        lock.withLock { last = next }
        progress(next)
    }

    func waiting(_ seconds: Int?) {
        let next = lock.withLock {
            last.waitingSeconds = seconds
            return last
        }
        progress(next)
    }
}

/// Whether the `done`th of `count` steps is reported: about 200 reports in all and the last,
/// since each one redraws the window and thousands of albums would stall it.
func isReported(_ done: Int, of count: Int) -> Bool {
    done == count || done % max(1, count / 200) == 0
}

/// Matches albums with one catalog, on one thread, as its connection is, or with releases the
/// API fetched and no catalog.
final class AlbumMatcher {
    let catalog: Catalog?
    /// Whether a release that is only video is left out, unless the tracks' ids name it or the
    /// user chose it.
    let skipsVideo: Bool

    init(_ catalog: Catalog?, skippingVideo: Bool) {
        self.catalog = catalog
        skipsVideo = skippingVideo
    }

    /// `album`'s match; `choice`, a release the user chose, is the match when the catalog or
    /// `fetched` has it, tiered by its own score alone, and is a candidate even when no key
    /// finds it. `found` are candidates the API found, after the catalog's, and `fetched` the
    /// releases it returned, which are read before the catalog.
    func match(
        _ album: DiscogsAlbum, choosing choice: Int? = nil,
        found extra: [(id: Int, foundBy: CandidateKey)] = [], fetched: [Int: CatalogRelease] = [:]
    ) throws -> AlbumMatch {
        let (tagged, isMatched) = Self.taggedIDs(album)
        let titles = TitleSimilarity(album.tracks.map(\.title))
        let seconds = album.tracks.map(\.seconds)
        var releases: [Int: CatalogRelease] = [:]
        var scores: [ReleaseScore] = []
        var found = try candidateIDs(for: album, in: catalog)
        var seen = Set(found.map(\.id))
        for candidate in extra where seen.insert(candidate.id).inserted { found.append(candidate) }
        let foundBy = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0.foundBy) })
        var candidates = found.map(\.id)
        if let choice, !candidates.contains(choice) { candidates.append(choice) }
        for id in candidates {
            guard let release = try fetched[id] ?? catalog?.release(id: id) else { continue }
            if skipsVideo, release.isVideo, id != choice, !tagged.contains(String(id)) {
                continue
            }
            releases[id] = release
            scores.append(ReleaseScore.best(release, seconds: seconds, titles: titles))
        }

        let tier: MatchTier
        let chosen: ReleaseScore?
        var tied = false
        if let choice, let score = scores.first(where: { $0.releaseID == choice }) {
            chosen = score
            tier = Self.chosenTier(score, album: album)
        } else if isMatched {
            tier = .matched
            chosen = scores.first { String($0.releaseID) == tagged.first }
        } else if scores.isEmpty {
            (tier, chosen) = (.noCandidate, nil)
        } else {
            let best: ReleaseScore
            (best, tied) = choose(scores, releases: releases, album: album)
            chosen = best
            if !tagged.isEmpty {
                tier = .incomplete
            } else if best.fitsTracklist {
                tier = !tied && best.durationsAgree ? .exact : .likely
            } else {
                tier = best.isLikely ? .likely : .incomplete
            }
        }

        let others = scores.filter { $0.releaseID != chosen?.releaseID }
            .map { MatchCandidate(releaseID: $0.releaseID, score: $0, foundBy: foundBy[$0.releaseID]) }
        return Self.made(
            album, tier: tier, chosen: chosen, release: chosen.flatMap { releases[$0.releaseID] },
            others: others, tied: tied, foundBy: chosen.flatMap { foundBy[$0.releaseID] },
            titles: titles,
            origin: chosen.map { fetched[$0.releaseID] != nil } == true ? .api : .catalog)
    }

    /// The release ids `album`'s tracks carry, and whether every track carries one, the same.
    private static func taggedIDs(_ album: DiscogsAlbum) -> (Set<String>, isMatched: Bool) {
        let ids = album.tracks.map(\.releaseID)
        let tagged = Set(ids.compactMap { $0 })
        return (tagged, tagged.count == 1 && !ids.contains(nil))
    }

    /// The tier of `score`, a release the user chose, by its own score alone.
    private static func chosenTier(_ score: ReleaseScore, album: DiscogsAlbum) -> MatchTier {
        let (tagged, isMatched) = taggedIDs(album)
        if isMatched, tagged.first == String(score.releaseID) { return .matched }
        if !tagged.isEmpty, !isMatched { return .incomplete }
        if score.fitsTracklist { return score.durationsAgree ? .exact : .likely }
        return score.isLikely ? .likely : .incomplete
    }

    /// The match of `album` at `tier` with `chosen`, the chosen release's score, and `others`,
    /// the other candidates in the order found, which it lists best first: its files paired
    /// with the release's tracks, and why it isn't Exact, and how sure it is.
    private static func made(
        _ album: DiscogsAlbum, tier: MatchTier, chosen: ReleaseScore?, release: CatalogRelease?,
        others: [MatchCandidate], tied: Bool, foundBy: CandidateKey?, titles: TitleSimilarity,
        origin: MatchOrigin
    ) -> AlbumMatch {
        let (tagged, isMatched) = taggedIDs(album)
        let mixedIDs = !tagged.isEmpty && !isMatched
        let seconds = album.tracks.map(\.seconds)
        let shown = chosen.map { $0.paired(titles: titles, seconds: seconds) }
        var mapping: [Int64: Int] = [:]
        if let chosen = shown {
            for (track, index) in zip(album.tracks, chosen.mapping) {
                if let index { mapping[track.fileID] = index }
            }
        }
        let sorted = others.enumerated().sorted { a, b in
            a.element.score.order != b.element.score.order
                ? a.element.score.order > b.element.score.order : a.offset < b.offset
        }
        return AlbumMatch(
            albumID: album.id, tier: tier, release: release, tracks: chosen?.tracks ?? [],
            mapping: mapping, candidates: sorted.map(\.element),
            reasons: NotExactReason.reasons(
                tier, shown, tied: tied, foundBy: foundBy, mixedIDs: mixedIDs),
            origin: origin,
            confidence: shown.map {
                MatchConfidence.percent(
                    $0, titles: titles, tied: tied, foundBy: foundBy, mixedIDs: mixedIDs)
            },
            foundBy: foundBy)
    }

    /// The best of `scores`, and whether others were as good after the tie-break. The best are
    /// every one that fits the tracklist when any does, else those ranked highest; among them
    /// the tie-break picks, and the first found of those it leaves.
    private func choose(
        _ scores: [ReleaseScore], releases: [Int: CatalogRelease], album: DiscogsAlbum
    ) -> (ReleaseScore, tied: Bool) {
        let best: [ReleaseScore]
        if scores.contains(where: \.fitsTracklist) {
            best = scores.filter(\.fitsTracklist)
        } else {
            let top = scores.map(\.order).max { $0 < $1 }!
            best = scores.filter { score in
                score.order.1 == top.1 && top.2 - score.rank <= MatchThreshold.tie
            }
        }
        return tieBreak(best, releases: releases, album: album)
    }
}
