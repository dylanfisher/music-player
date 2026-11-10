import Foundation
import Library
import Testing

@testable import Discogs
@testable import DiscogsTagger
@testable import Fixtures
@testable import Metadata
@testable import Settings
@testable import TagWriter

// Albums, releases and stand-ins for the index, the catalog and the files, for the tagger's
// model and window: nothing here reads or writes a real file.

/// An album of `titles`, its files numbered from `id * 100`.
func album(
    _ id: Int64, _ title: String, artist: String = "Persuader", titles: [String],
    releaseID: String? = nil
) -> DiscogsAlbum {
    DiscogsAlbum(
        id: id, title: title, artist: artist,
        tracks: titles.enumerated().map { number, title in
            DiscogsAlbum.Track(
                fileID: id * 100 + Int64(number), title: title, seconds: 200,
                trackNumber: number + 1, releaseID: releaseID)
        })
}

/// A release with a track per title.
func release(_ id: Int, _ title: String, titles: [String]) -> CatalogRelease {
    CatalogRelease(
        id: id, title: title,
        artists: [CatalogArtistCredit(id: 1, name: "Persuader", nameVariation: nil, join: nil)],
        labels: [CatalogRelease.Label(id: 5, name: "Svek", catalogNumber: "SK \(id)")],
        formats: [CatalogRelease.Format(name: "CD", quantity: 1, text: nil, descriptions: [])],
        country: "Sweden", released: "2000",
        tracks: titles.enumerated().map {
            CatalogTrack(kind: .track, position: String($0.offset + 1), title: $0.element)
        })
}

/// `album` matched in `tier` to `release`, each file on its track in order, with `reasons`,
/// `confidence` and `safety`.
func match(
    _ album: DiscogsAlbum, _ release: CatalogRelease?, tier: MatchTier,
    candidates: [Int] = [], reasons: [NotExactReason] = [], confidence: Int? = nil,
    safety: MatchSafety? = nil
) -> AlbumMatch {
    AlbumMatch(
        albumID: album.id, tier: tier, release: release, tracks: release?.tracks ?? [],
        mapping: Dictionary(
            uniqueKeysWithValues: album.tracks.enumerated().compactMap { index, track in
                index < (release?.tracks.count ?? 0) ? (track.fileID, index) : nil
            }),
        candidates: candidates.map {
            MatchCandidate(
                releaseID: $0,
                score: ReleaseScore(
                    releaseID: $0, tracks: [], mapping: [], sameCount: true, tracklist: 0.7,
                    titlesInOrder: false, durationsCompared: 0, durationsAgreeing: 0))
        }, reasons: reasons, confidence: confidence, safety: safety)
}

/// What the stand-ins saw, from any thread.
final class Seen: @unchecked Sendable {
    // Every field is guarded by `lock`.
    private let lock = NSLock()
    private var _reviews: [(DiscogsReview?, [Int64])] = []
    private var _matched: [[Int64: Int]] = []
    private var _reads: [[Int64]] = []
    private var _skips: [Bool] = []
    private var _sources: [DiscogsSource] = []
    private var _chosen: [(release: [Int64: Int], source: DiscogsSource)] = []

    var reviews: [(DiscogsReview?, [Int64])] { lock.withLock { _reviews } }
    /// The releases chosen each match was asked with.
    var matched: [[Int64: Int]] { lock.withLock { _matched } }
    var reads: [[Int64]] { lock.withLock { _reads } }
    /// Whether each match was asked to skip video releases.
    var skips: [Bool] { lock.withLock { _skips } }
    /// The source each match was asked to look releases up in.
    var sources: [DiscogsSource] { lock.withLock { _sources } }
    /// Each release chosen, by album id, and the source it was to be loaded from.
    var chosen: [(release: [Int64: Int], source: DiscogsSource)] { lock.withLock { _chosen } }

    func review(_ review: DiscogsReview?, _ files: [Int64]) {
        lock.withLock { _reviews.append((review, files)) }
    }
    func match(_ chosen: [Int64: Int], skipping: Bool, source: DiscogsSource = .catalog) {
        lock.withLock {
            _matched.append(chosen)
            _skips.append(skipping)
            _sources.append(source)
        }
    }
    func choose(_ release: [Int64: Int], source: DiscogsSource) {
        lock.withLock { _chosen.append((release, source)) }
    }
    func read(_ ids: [Int64]) { lock.withLock { _reads.append(ids) } }
}

/// Holds a background call until the test lets it go.
final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func wait() { semaphore.wait() }
    func open() { semaphore.signal() }
}

/// A file of `album`'s at `index` with `tags`, as a FLAC.
func file(_ album: DiscogsAlbum, _ index: Int, _ tags: TrackTags = TrackTags()) -> AlbumFile {
    let id = album.tracks[index].fileID
    return AlbumFile(
        id: id, path: "/m/\(album.id)/\(id).flac",
        metadata: TrackMetadata(
            tags: tags,
            audio: TrackAudio(
                codec: .flac, sampleRateHz: 44_100, bitsPerSample: 16, channels: 2,
                lengthFrames: 44_100 * 200),
            art: nil))
}

/// The choices as the settings' defaults make them.
/// A catalog in place, as the window describes it.
let readyCatalog = TaggerModel.CatalogState.ready(
    CatalogStatus(
        dumpDate: "20261101", importedAt: Date(timeIntervalSince1970: 1_794_000_000),
        sizeBytes: 12_345_000_000,
        url: URL(fileURLWithPath: "/Volumes/Scratch/discogs-catalog.sqlite", isDirectory: false)))

let defaultChoices = TaggerChoices(
    keepExistingValues: false, skipVideo: true, fillSortArtist: false)

/// A model over `albums`, its catalog checked, matched by `matches` (by album id, a release the user chose giving
/// that release), whose files are `files`.
@MainActor
func model(
    _ seen: Seen, albums: [DiscogsAlbum],
    matches: @escaping @Sendable (DiscogsAlbum, Int?) -> AlbumMatch,
    reviews: [Int64: DiscogsReview] = [:],
    files: @escaping @Sendable ([Int64]) -> [AlbumFile] = { _ in [] },
    catalog: TaggerModel.CatalogState = readyCatalog, gate: Gate? = nil,
    mapping: DiscogsMapping = DiscogsPreset.minimal.mapping,
    choices: TaggerChoices = defaultChoices, unfinished: UnfinishedImport? = nil,
    source: DiscogsSource? = .catalog,
    matchError: (any Error & Sendable)? = nil,
    cover: @escaping @Sendable (Int) async -> Result<Cover, CoverProblem> = { _ in
        .failure(.needsToken)
    },
    importing: @escaping DiscogsTagger.Import = { _, _, _ in throw CatalogImportError.stopped },
    paths: @escaping @Sendable ([Int64]) async throws -> [Int64: String] = { _ in [:] },
    pixels: @escaping @Sendable (String) async throws -> Int? = { _ in nil },
    lookUp: @escaping @Sendable (ReleaseQuery, DiscogsAlbum) async throws -> ReleaseLookup = {
        _, _ in throw TaggerModel.LookUpUnavailable()
    }
) async -> TaggerModel {
    let made = TaggerModel(
        effects: .init(
            albums: { albums },
            reviews: { reviews },
            review: { seen.review($0, $1) },
            match: { albums, chosen, skipping, source, progress in
                seen.match(chosen, skipping: skipping, source: source)
                if let matchError { throw matchError }
                var done: [AlbumMatch] = []
                for album in albums {
                    gate?.wait()
                    try Task.checkCancellation()
                    done.append(matches(album, chosen[album.id]))
                    progress(AlbumMatchProgress(albumsDone: done.count, albumCount: albums.count))
                }
                return done
            },
            choose: { album, _, id, source in
                seen.choose([album.id: id], source: source)
                if let matchError { throw matchError }
                gate?.wait()
                return matches(album, id)
            },
            summaries: { ids in
                ids.map {
                    ReleaseSummary(
                        id: $0, artist: "Persuader", title: "Release \($0)", label: "Svek",
                        catalogNumber: "SK \($0)", country: "Sweden", year: "2000", format: "CD",
                        trackCount: 3)
                }
            },
            release: { id in
                ReleaseDetail(
                    summary: ReleaseSummary(
                        id: id, artist: "Persuader", title: "Release \(id)", label: "Svek",
                        catalogNumber: "SK \(id)", country: "Sweden", year: "2000", format: "CD",
                        trackCount: 2),
                    tracks: [
                        ReleaseDetail.Track(position: "", title: "Side A", seconds: nil),
                        ReleaseDetail.Track(position: "A1", title: "Östermalm", seconds: 285),
                        ReleaseDetail.Track(position: "A2", title: "Gamla Stan", seconds: 370),
                    ])
            },
            read: { ids, progress in
                seen.read(ids)
                progress(ids.count)
                return (files(ids), [])
            },
            checkCatalog: { catalog }, unfinishedImport: { unfinished },
            importCatalog: importing, cover: cover, paths: paths, pixels: pixels, lookUp: lookUp),

        mapping: mapping, savedMappings: [], choices: choices, source: source)
    await made.checkCatalog()

    return made
}

/// Waits up to `waitLimit` for `condition`, letting the main actor's tasks run.
@MainActor
func eventually(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(waitLimit)
    while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(condition())
}
