import AppKit
import Discogs
import DiscogsTagger
import Fixtures
import Foundation
import HTTPSClient
import Library
import Settings
import TagWriter

/// The Discogs API for the window's row, which never connects: the bench opens no socket to
/// the internet.
private let offlineDiscogs = DiscogsAPI(
    token: nil, userAgent: DiscogsAPI.userAgent(version: "offline"),
    transport: { _, _, _, _ throws(HTTPSError) in throw .offline },
    cache: DiscogsCache(read: { _, _ in nil }, store: { _, _, _ in }, remove: { _, _ in }),
    covers: CoverStore(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent(
            "bench-discogs-covers-\(UUID().uuidString)", isDirectory: true)))

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

/// The owner's tagged albums (phase 73): the fixture library's first albums of four tracks or
/// more, each one master of the shaped fixture dump.
private let shapedAlbumCount = 1_741

/// The fixture library's albums the shaped dump is made for, and that dump imported into a
/// catalog of its own, in the caches beside the fixtures.
/// Set once per run, then only read.
private struct ShapedCatalog: @unchecked Sendable {
    var albums: [DiscogsAlbum]
    var shaped: DiscogsDumpFixture.Shaped
    var catalog: URL
    var catalogMB: Double
}

private let shapedCatalog = Result { () throws -> ShapedCatalog in
    let index = try LibraryIndex(at: try scannedLibrary.get().databaseURL)
    let albums = Array(
        try index.discogsAlbums().filter { $0.tracks.count >= 4 }.prefix(shapedAlbumCount))
    guard albums.count == shapedAlbumCount else {
        throw BenchError.expected("\(shapedAlbumCount) fixture albums: \(albums.count)")
    }
    let directory = try emptyCacheDirectory("bench-discogs-shaped")
    let dumps = directory.appendingPathComponent("dumps", isDirectory: true)
    let shaped = try DiscogsDumpFixture.writeShapedSet(
        date: "20261101",
        albums: albums.map { album in
            DiscogsDumpFixture.Album(
                artist: album.artist, title: album.title,
                tracks: album.tracks.map { ($0.title ?? "", $0.seconds) })
        }, in: dumps)
    let catalog = directory.appendingPathComponent("catalog.sqlite", isDirectory: false)
    let summary = try waited {
        try await importCatalog(from: dumps, to: catalog, outsideOf: []) { _ in }
    }
    guard summary.records[.releases] == shaped.releases else {
        throw BenchError.expected("\(shaped.releases) releases imported: \(summary.records)")
    }
    return ShapedCatalog(
        albums: albums, shaped: shaped, catalog: catalog,
        catalogMB: Double(summary.catalogBytes) / 1e6)
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
        name:
            "discogs: Analyze \(shapedAlbumCount) fixture albums, masters of 20 to 100 releases"
            + " and an artist-only share",
        budget: Budget(appleSilicon: 10, oldMac: 40, unit: .seconds)
    ) {
        let shaped = try shapedCatalog.get()
        let albums = shaped.albums
        let before = try footprintMB()
        let peak = PeakFootprint()
        var matches: [AlbumMatch] = []
        let elapsed = try seconds {
            matches = try waited {
                try await matchAlbums(
                    albums, catalogAt: shaped.catalog, choosing: [:], skippingVideo: true
                ) { _ in }
            }
        }
        let peakMB = try peak.stop()
        let afterMB = try footprintMB()
        let tiers = Dictionary(grouping: matches, by: \.tier).mapValues(\.count)
        let byArtist = matches.count { $0.foundBy == .artist }
        let candidates = matches.map { $0.candidates.count + ($0.releaseID == nil ? 0 : 1) }
        return Measured(
            value: elapsed,
            notes: [
                String(format: "%.2f ms an album; ", elapsed * 1000 / Double(albums.count))
                    + MatchTier.allCases.map { "\(tiers[$0] ?? 0) \($0.rawValue)" }
                    .joined(separator: ", "),
                "\(shaped.shaped.releases) releases in \(shaped.shaped.masters) masters,"
                    + String(format: " a %.0f MB catalog; ", shaped.catalogMB)
                    + "\(candidates.reduce(0, +) / max(albums.count, 1)) candidates an album,"
                    + " \(candidates.max() ?? 0) at most; \(byArtist) found by artist alone of the"
                    + " \(shaped.shaped.artistOnly.count) titled otherwise",
                String(
                    format: "footprint %.0f MB added at the peak, %.0f MB still held with the"
                        + " matches",
                    peakMB - before, afterMB - before),
            ])
    },
    Benchmark(
        name:
            "discogs: the tagger window with \(shapedAlbumCount) albums analyzed, a refresh of its"
            + " Exact tab (median of 20)",
        budget: Budget(appleSilicon: 10, oldMac: 40, unit: .milliseconds)
    ) {
        let run = try taggerRun.get()
        return Measured(
            value: run.refreshMs,
            notes: [
                String(
                    format: "%d albums in Exact; analyzed in %.1f s with the window open",
                    run.exactAlbums, run.analyzeSeconds)
            ])
    },
    Benchmark(
        name:
            "discogs: the tagger window with \(shapedAlbumCount) albums, Apply to All in Exact's"
            + " write progress, two reports a file, to the main thread's last",
        budget: Budget(appleSilicon: 5, oldMac: 20, unit: .seconds)
    ) {
        let run = try taggerRun.get()
        return Measured(
            value: run.progressSeconds,
            notes: [
                "\(run.reports) reports for \(run.files) files, each handed to the window as the"
                    + String(
                        format: " tag writer's are: %.2f ms a report",
                        run.progressSeconds * 1000
                            / Double(max(run.reports, 1))),
                String(
                    format: "the plan, reading the files, %.1f s to the confirmation",
                    run.planSeconds),
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

/// The tagger window over a copy of the fixture index, scoped to the shaped albums as a
/// library selection scopes it, which analyzes them as it opens; then a refresh of its Exact
/// tab, timed, and Apply to All in Exact, clicked and confirmed, its edits handed to a stand-in
/// writer that writes nothing and reports as the tag writer does, through the main queue.
private struct TaggerRun: Sendable {
    var exactAlbums: Int
    var analyzeSeconds: Double
    var refreshMs: Double
    var planSeconds: Double
    var files: Int
    var reports: Int
    var progressSeconds: Double
}

private let taggerRun = Result { () throws -> TaggerRun in
    let shaped = try shapedCatalog.get()
    let fileIDs = shaped.albums.flatMap { $0.tracks.map(\.fileID) }
    return try withLibraryCopy("tagger") { databaseURL in
        try onMainActor {
            let tagger = DiscogsTagger(
                reader: try LibraryReader(databaseURL: databaseURL), catalog: shaped.catalog,
                mapping: DiscogsPreset.oneToOne.mapping, savedMappings: [],
                choices: TaggerChoices(
                    keepExistingValues: false, skipVideo: true, fillSortArtist: false),
                source: .catalog, api: { offlineDiscogs },
                importing: { _, _, _ in throw CatalogImportError.stopped })
            tagger.selectedTracks = { fileIDs }
            let written = StandInWrite()
            tagger.write = { files, _, progress, _, completion in
                written.start(files.count, progress: progress, completion: completion)
            }
            let opened = DispatchTime.now().uptimeNanoseconds
            tagger.show()
            guard let window = tagger.window, let content = window.contentView else {
                throw BenchError.expected("the tagger's window")
            }
            let apply = try button(in: content, action: "applyAll")
            guard let tabs = subviews(of: content, NSSegmentedControl.self).first,
                let exact = (0..<tabs.segmentCount).first(where: {
                    tabs.label(forSegment: $0)?.hasPrefix("Exact ") == true
                })
            else { throw BenchError.expected("the tagger's tabs") }
            // The albums are replaced once the analysis ends.
            try await waitFor("the analysis", seconds: 300) {
                tabs.label(forSegment: exact) != "Exact (0)"
            }
            let analyzeSeconds = Double(DispatchTime.now().uptimeNanoseconds - opened) / 1e9
            tabs.selectedSegment = exact
            tabs.sendAction(tabs.action, to: tabs.target)
            let refreshMs = try medianMilliseconds(iterations: 20) {
                tagger.mappingChanged(DiscogsPreset.oneToOne.mapping, saved: [])
            }
            let exactAlbums = Int(tabs.label(forSegment: exact)!.filter(\.isNumber)) ?? 0
            let clicked = DispatchTime.now().uptimeNanoseconds
            apply.performClick(nil)
            try await waitFor("Apply's confirmation", seconds: 300) { window.attachedSheet != nil }
            let planSeconds = Double(DispatchTime.now().uptimeNanoseconds - clicked) / 1e9
            // The alert's first button, Apply, is its default.
            let confirm = try (window.attachedSheet?.defaultButtonCell?.controlView as? NSButton)
                .unwrapped("the confirmation's Apply button")
            confirm.performClick(nil)
            try await waitFor("the stand-in write", seconds: 3600) { written.seconds != nil }
            window.close()
            return TaggerRun(
                exactAlbums: exactAlbums, analyzeSeconds: analyzeSeconds,
                refreshMs: refreshMs, planSeconds: planSeconds, files: written.files,
                reports: written.reports, progressSeconds: written.seconds!)
        }
    }
}

/// The tagger's writer in the tagger row: it writes nothing, and hands the window a read and
/// a written report for each file through the main queue, as `TagEditing` hands on the tag
/// writer's, then the completion; and times them to the completion.
@MainActor
private final class StandInWrite {
    private(set) var files = 0
    private(set) var reports = 0
    private(set) var seconds: Double?

    func start(
        _ count: Int, progress: @escaping (TagWriteProgress) -> Void,
        completion: @escaping (Set<String>) -> Void
    ) {
        let begun = DispatchTime.now().uptimeNanoseconds
        files = count
        let sent = MainCallback(progress)
        var reported = TagWriteProgress.combined([], total: count)
        for _ in 0..<count {
            for step in 0..<2 {
                if step == 0 { reported.read += 1 } else { reported.written += 1 }
                let report = reported
                reports += 1
                DispatchQueue.main.async { MainActor.assumeIsolated { sent.call(report) } }
            }
        }
        let finished = MainCallback(completion)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { [self] in
                finished.call([])
                seconds = Double(DispatchTime.now().uptimeNanoseconds - begun) / 1e9
            }
        }
    }
}

/// A main-actor closure carried through `DispatchQueue.main`, which only calls it there.
private final class MainCallback<T>: @unchecked Sendable {
    private let body: (T) -> Void

    init(_ body: @escaping (T) -> Void) { self.body = body }

    @MainActor func call(_ value: T) { body(value) }
}

/// Every view of `type` under `view`, depth first.
@MainActor
private func subviews<T: NSView>(of view: NSView, _ type: T.Type) -> [T] {
    view.subviews.flatMap { ([$0 as? T].compactMap { $0 }) + subviews(of: $0, type) }
}

/// The button under `view` whose action is the selector `action`.
@MainActor
private func button(in view: NSView, action: String) throws -> NSButton {
    try subviews(of: view, NSButton.self).first { $0.action == NSSelectorFromString(action) }
        .unwrapped("the button that sends \(action)")
}

/// Turns the main run loop until `done` says yes, or throws after `seconds`.
@MainActor
private func waitFor(_ what: String, seconds: Double, _ done: () -> Bool) async throws {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while !done() {
        guard Date() < deadline else { throw BenchError.expected("\(what) within \(seconds) s") }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

extension Optional {
    fileprivate func unwrapped(_ what: String) throws -> Wrapped {
        guard let self else { throw BenchError.expected(what) }
        return self
    }
}

/// A value an import's progress sets from its thread, read once the import is done.
/// `stored` is guarded by `lock`.
private final class LockedValue<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { stored = value }

    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
