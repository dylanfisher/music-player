import AppKit
import Discogs
import DiscogsTagger
import Fixtures
import Foundation
import HTTPSClient
import Library
import Settings

/// The Discogs API for the window's row, which never connects: the bench opens no socket to
/// the internet.
private let offlineDiscogs = DiscogsAPI(
    token: nil, userAgent: DiscogsAPI.userAgent(version: "offline"),
    transport: { _, _, _, _ throws(HTTPSError) in throw .offline },
    cache: DiscogsCache(read: { _, _ in nil }, store: { _, _, _ in }))

/// The releases in the import rows' fixture dump: about a thousandth of the 2026-11-01 dump.
private let fixtureReleases = 20_000

/// The fixture albums Analyze matches: every fifth release of the fixture dump, as a library
/// tags it without a release id. Those the dump gives no master are found by their artist and
/// title, as an untagged album is; the rest by their label and catalog number, as the fixture
/// dump has no masters to find them by title.
private let fixtureAlbums = 2_000

/// One import of the fixture dump into a new catalog, with the footprint it added at its peak.
/// The catalog stays, in the caches beside the fixtures, for the matching rows.
private struct FixtureImport {
    var summary: CatalogImportSummary
    var dumps: URL
    var catalog: URL
    var footprintBeforeMB: Double
    var footprintPeakMB: Double
}

private let fixtureImport = Result { () throws -> FixtureImport in
    let directory = try emptyCacheDirectory("bench-discogs")
    let dumps = directory.appendingPathComponent("dumps", isDirectory: true)
    try DiscogsDumpFixture.writeSet(
        date: "20261101",
        releases: DiscogsDumpFixture.syntheticReleases(count: fixtureReleases), in: dumps)
    let catalog = directory.appendingPathComponent("catalog.sqlite", isDirectory: false)
    let before = try footprintMB()
    let peak = PeakFootprint()
    let summary = try waited {
        try await importCatalog(from: dumps, to: catalog, outsideOf: []) { _ in }
    }
    guard summary.records[.releases] == fixtureReleases else {
        throw BenchError.expected("\(fixtureReleases) releases imported: \(summary.records)")
    }
    return FixtureImport(
        summary: summary, dumps: dumps, catalog: catalog, footprintBeforeMB: before,
        footprintPeakMB: try peak.stop())
}

/// The fixture dump imported again into a catalog of its own, stopped halfway by its task's
/// cancel and resumed (ADR 0134); then once more with a checkpoint every 256 KB of input, for
/// what a checkpoint costs.
private struct ResumedImport {
    var stoppedSeconds: Double
    var stoppedAt: Double
    var resumed: CatalogImportSummary
    var checkpointed: CatalogImportSummary
    var checkpoints: Int
}

private let resumedImport = Result { () throws -> ResumedImport in
    let straight = try fixtureImport.get()
    let dumps = straight.dumps
    let directory = try emptyCacheDirectory("bench-discogs-resume")
    let catalog = directory.appendingPathComponent("catalog.sqlite", isDirectory: false)
    let stoppedAt = LockedValue(0.0)
    let stoppedSeconds = try seconds {
        do {
            _ = try waited {
                try await importCatalog(from: dumps, to: catalog, outsideOf: []) { progress in
                    guard progress.fraction >= 0.5, stoppedAt.value == 0 else { return }
                    stoppedAt.value = progress.fraction
                    // The import's own task, as Stop cancels it.
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            throw BenchError.expected("the import stopped halfway")
        } catch CatalogImportError.stopped {}
    }
    let resumed = try waited {
        try await importCatalog(from: dumps, to: catalog, outsideOf: []) { _ in }
    }
    guard resumed.resumedBytes > 0, resumed.records == straight.summary.records else {
        throw BenchError.expected("a resumed import of every record: \(resumed)")
    }
    let checkpoints = LockedValue(0)
    let checkpointed = try waited {
        try await importCatalog(
            from: dumps, to: directory.appendingPathComponent("checkpointed.sqlite"),
            outsideOf: [], checkpointBytes: 256 << 10
        ) { progress in
            if progress.checkpointed { checkpoints.value += 1 }
        }
    }
    return ResumedImport(
        stoppedSeconds: stoppedSeconds, stoppedAt: stoppedAt.value, resumed: resumed,
        checkpointed: checkpointed, checkpoints: checkpoints.value)
}

/// Release `id` of the fixture dump as a library album, its tracks' titles and lengths as
/// `DiscogsDumpFixture.syntheticReleases` writes them.
private func fixtureAlbum(_ id: Int) -> DiscogsAlbum {
    let hasMaster = id % 4 != 0
    return DiscogsAlbum(
        id: Int64(id), title: "Album Number \(id)", artist: "Artist \(id % 997)",
        label: hasMaster ? "Label \(id % 211)" : nil, catalogNumber: hasMaster ? "LBL \(id)" : nil,
        tracks: (1...10).map { track in
            DiscogsAlbum.Track(
                fileID: Int64(id * 100 + track), title: "Track Title \(track) of \(id)",
                seconds: Double((3 + track % 5) * 60 + 10 + track), trackNumber: track)
        })
}

private let analyzeRun = Result { () throws -> (seconds: Double, tiers: [MatchTier: Int]) in
    let catalog = try fixtureImport.get().catalog
    let albums = (0..<fixtureAlbums).map { fixtureAlbum($0 * 5 + 4) }
    var matches: [AlbumMatch] = []
    let elapsed = try seconds {
        matches = try waited {
            try await matchAlbums(albums, catalogAt: catalog, choosing: [:], skippingVideo: true) {
                _ in
            }
        }
    }
    return (elapsed, Dictionary(grouping: matches, by: \.tier).mapValues(\.count))
}

let discogsBenchmarks = [
    Benchmark(
        name: "discogs: import a \(fixtureReleases)-release fixture dump",
        budget: Budget(appleSilicon: 5, oldMac: 20, unit: .seconds)
    ) {
        let run = try fixtureImport.get()
        return Measured(
            value: run.summary.seconds,
            notes: [
                String(
                    format: "%.0f releases a second, %.1f MB gzip, %.0f MB added at the peak",
                    Double(fixtureReleases) / run.summary.seconds,
                    Double(run.summary.compressedBytes) / 1e6,
                    run.footprintPeakMB - run.footprintBeforeMB)
            ])
    },
    Benchmark(
        name: "discogs: import that fixture dump stopped past halfway, then resumed",
        budget: Budget(appleSilicon: 6, oldMac: 24, unit: .seconds)
    ) {
        let straight = try fixtureImport.get().summary
        let run = try resumedImport.get()
        let perCheckpoint =
            (run.checkpointed.seconds - straight.seconds) / Double(max(run.checkpoints, 1))
        return Measured(
            value: run.stoppedSeconds + run.resumed.seconds,
            notes: [
                String(
                    format: "%.2f s to the stop at %.0f%%, %.2f s resumed after %.1f MB;"
                        + " %.2f s straight through",
                    run.stoppedSeconds, run.stoppedAt * 100, run.resumed.seconds,
                    Double(run.resumed.resumedBytes) / 1e6, straight.seconds),
                String(
                    format: "%.2f s with %d checkpoints, one every 256 KB of input: %.0f ms each",
                    run.checkpointed.seconds, run.checkpoints, perCheckpoint * 1000),
            ])
    },
    Benchmark(
        name: "discogs: the catalog of that fixture dump",
        budget: Budget(appleSilicon: 60, oldMac: 60, unit: .megabytes)
    ) {
        Measured(value: Double(try fixtureImport.get().summary.catalogBytes) / 1e6)
    },
    Benchmark(
        name: "discogs: Analyze \(fixtureAlbums) fixture albums against that catalog",
        budget: Budget(appleSilicon: 2, oldMac: 8, unit: .seconds)
    ) {
        let run = try analyzeRun.get()
        let tiers = MatchTier.allCases.map { "\(run.tiers[$0] ?? 0) \($0.rawValue)" }
        return Measured(
            value: run.seconds,
            notes: [
                String(format: "%.2f ms an album; ", run.seconds * 1000 / Double(fixtureAlbums))
                    + tiers.joined(separator: ", ")
            ])
    },
    Benchmark(
        name: "discogs: one fixture album's candidates, matched and listed (median of 20)",
        budget: Budget(appleSilicon: 5, oldMac: 20, unit: .milliseconds)
    ) {
        let catalog = try fixtureImport.get().catalog
        var listed = 0
        var samples: [Double] = []
        for index in 0...20 {
            let album = fixtureAlbum(index * 997 + 3)
            let start = DispatchTime.now().uptimeNanoseconds
            listed = try waited {
                let match = try await matchAlbums(
                    [album], catalogAt: catalog, choosing: [:], skippingVideo: true
                ) {
                    _ in
                }[0]
                let ids = [match.releaseID].compactMap { $0 } + match.candidates.map(\.releaseID)
                return try await releaseSummaries(ids, catalogAt: catalog).count
            }
            // The first, untimed, as `medianMilliseconds` does.
            if index > 0 {
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
        }
        return Measured(
            value: samples.sorted()[samples.count / 2],
            notes: ["the catalog opened for each; \(listed) releases listed for the last"])
    },
    Benchmark(
        name: "discogs: open the tagger window, to it on screen with its catalog (median of 5)",
        budget: Budget(appleSilicon: 100, oldMac: 400, unit: .milliseconds)
    ) {
        let catalog = try fixtureImport.get().catalog
        let library = try emptyCacheDirectory("bench-discogs-library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let databaseURL = libraryFileURL(in: library)
        _ = try LibraryIndex(at: databaseURL)
        let samples = try onMainActor {
            var samples: [Double] = []
            for run in 0...5 {
                let tagger = DiscogsTagger(
                    reader: try LibraryReader(databaseURL: databaseURL), catalog: catalog,
                    mapping: DiscogsPreset.oneToOne.mapping, savedMappings: [],
                    choices: TaggerChoices(
                        keepExistingValues: false, skipVideo: true, fillSortArtist: false),
                    source: .catalog, api: { offlineDiscogs },
                    importing: { _, _, _ in throw CatalogImportError.stopped })
                let start = DispatchTime.now().uptimeNanoseconds
                tagger.show()
                guard let window = tagger.window, window.isVisible else {
                    throw BenchError.expected("the tagger's window on screen")
                }
                window.displayIfNeeded()
                // What the window checks as it opens, off the main thread.
                try await Task.detached { _ = try Catalog(at: catalog) }.value
                let shown = DispatchTime.now().uptimeNanoseconds
                window.close()
                if run > 0 { samples.append(Double(shown - start) / 1e6) }
            }
            return samples
        }
        return Measured(
            value: samples.sorted()[samples.count / 2],
            notes: [
                "the runs: " + samples.map { String(format: "%.1f ms", $0) }.joined(separator: ", ")
            ])
    },
]

/// A value an import's progress sets from its thread, read once the import is done.
private final class LockedValue<T: Sendable>: @unchecked Sendable {
    // `stored` is guarded by `lock`.
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { stored = value }

    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
