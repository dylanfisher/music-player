import Foundation
import Library
import Testing

@testable import Discogs
@testable import DiscogsTagger
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

/// `album` matched in `tier` to `release`, each file on its track in order.
func match(
    _ album: DiscogsAlbum, _ release: CatalogRelease?, tier: MatchTier,
    candidates: [Int] = []
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
        })
}

/// What the stand-ins saw, from any thread.
final class Seen: @unchecked Sendable {
    // Every field is guarded by `lock`.
    private let lock = NSLock()
    private var _reviews: [(DiscogsReview?, [Int64])] = []
    private var _matched: [[Int64: Int]] = []
    private var _reads: [[Int64]] = []
    private var _skips: [Bool] = []

    var reviews: [(DiscogsReview?, [Int64])] { lock.withLock { _reviews } }
    /// The releases chosen each match was asked with.
    var matched: [[Int64: Int]] { lock.withLock { _matched } }
    var reads: [[Int64]] { lock.withLock { _reads } }
    /// Whether each match was asked to skip video releases.
    var skips: [Bool] { lock.withLock { _skips } }

    func review(_ review: DiscogsReview?, _ files: [Int64]) {
        lock.withLock { _reviews.append((review, files)) }
    }
    func match(_ chosen: [Int64: Int], skipping: Bool) {
        lock.withLock {
            _matched.append(chosen)
            _skips.append(skipping)
        }
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
    catalog: TaggerModel.CatalogState = .ready, gate: Gate? = nil,
    mapping: DiscogsMapping = DiscogsPreset.minimal.mapping,
    choices: TaggerChoices = defaultChoices, unfinished: UnfinishedImport? = nil,
    importing: @escaping DiscogsTagger.Import = { _, _, _ in throw CatalogImportError.stopped }
) async -> TaggerModel {
    let made = TaggerModel(
        effects: .init(
            albums: { albums },
            reviews: { reviews },
            review: { seen.review($0, $1) },
            match: { albums, chosen, skipping, progress in
                seen.match(chosen, skipping: skipping)
                var done: [AlbumMatch] = []
                for album in albums {
                    gate?.wait()
                    try Task.checkCancellation()
                    done.append(matches(album, chosen[album.id]))
                    progress(AlbumMatchProgress(albumsDone: done.count, albumCount: albums.count))
                }
                return done
            },
            summaries: { ids in
                ids.map {
                    ReleaseSummary(
                        id: $0, artist: "Persuader", title: "Release \($0)", label: "Svek",
                        catalogNumber: "SK \($0)", country: "Sweden", year: "2000", format: "CD")
                }
            },
            read: { ids, progress in
                seen.read(ids)
                progress(ids.count)
                return (files(ids), [])
            },
            checkCatalog: { catalog }, unfinishedImport: { unfinished },
            importCatalog: importing),
        mapping: mapping, savedMappings: [], choices: choices)
    await made.checkCatalog()
    return made
}

/// Waits up to two seconds for `condition`, letting the main actor's tasks run.
@MainActor
func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<200 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(condition())
}
