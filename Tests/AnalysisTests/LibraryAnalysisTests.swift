import Foundation
import Metadata
import Settings
import Testing

@testable import Analysis
@testable import Fixtures
@testable import Library

/// A library of three analysis fixtures, scanned into a database of its own.
private struct ScannedFixtures {
    let databaseURL: URL
    /// The files' paths, in the order the pass takes them.
    let paths: [String]

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-analysis-\(UUID().uuidString)")
        let music = directory.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let fixtures = try defaultPlaybackFixturesDirectory()
        var paths: [String] = []
        for (name, fixture) in [
            ("a", AnalysisFixture.lowPass16k), ("b", .padded), ("c", .fullBand),
        ] {
            let file = music.appendingPathComponent("\(name).flac")
            try FileManager.default.copyItem(
                at: try analysisFixture(fixture, in: fixtures), to: file)
            paths.append(file.path)
        }
        databaseURL = libraryFileURL(in: directory)
        let summary = try LibraryScanner(databaseURL: databaseURL).scan(
            WatchedFolder(path: music.path, kind: .local))
        #expect(summary.read == 3 && summary.failed == 0)
        self.paths = paths
    }

    func cache() -> MeasuresCache { MeasuresCache(databaseURL: databaseURL) }
}

/// What a run reported and which files it was asked to analyze, as they come.
private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var reported: [LibraryAnalysis.Progress] = []
    private var asked: [String] = []
    private var scanning = false

    func report(_ progress: LibraryAnalysis.Progress) {
        lock.withLock { reported.append(progress) }
    }
    func ask(_ path: String) { lock.withLock { asked.append(path) } }
    var progress: [LibraryAnalysis.Progress] { lock.withLock { reported } }
    var paths: [String] { lock.withLock { asked } }
    var scanRuns: Bool {
        get { lock.withLock { scanning } }
        set { lock.withLock { scanning = newValue } }
    }
}

/// Measures that earn no verdict, for a stand-in analysis.
private let clean = FileMeasures(
    formatID: "flac", sampleRateHz: 44_100, storedBits: 16, channels: 2, isFloat: false,
    durationSeconds: 6, cutoffHz: nil, cutoffSteepnessDBPerKHz: nil, effectiveBits: 16,
    identicalChannels: false, peakDBFS: -1, truePeakDBTP: -0.9, clippedRuns: 0,
    dynamicRange: 10)

/// Waits up to `waitLimit` for `condition`.
private func eventually(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(waitLimit)
    while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(condition())
}

@Test func aRunMeasuresEveryFileAndARunAfterARelaunchFindsNoneLeft() async throws {
    let library = try ScannedFixtures()
    let heard = Heard()
    let pass = LibraryAnalysis(
        cache: library.cache(), scanRunning: { false }, report: heard.report)
    let ended = await pass.start().value
    #expect(ended.stage == .finished)
    #expect(ended.analyzed == 3 && ended.total == 3 && ended.failed == 0)
    // The fixtures take less than a report's interval, so the count goes out about once
    // between the start and the end, with a file's name.
    let counts = heard.progress.map(\.analyzed)
    #expect(counts.first == 0 && counts.last == 3 && counts == counts.sorted())
    #expect(heard.progress.count == 3 || heard.progress.count == 4)
    #expect(heard.progress[1].file.map(\.isEmpty) == false && ended.file == nil)
    #expect(ended.text == "Library analyzed: 3 files")

    let index = try LibraryIndex(at: library.databaseURL)
    let rows = try index.rows(ids: try index.trackIDs(sortedBy: .path))
    #expect(rows.map { $0.cutoffHz.map { ($0 / 1000).rounded() } } == [16, nil, nil])
    #expect(rows.map(\.effectiveBits) == [16, 16, 16])

    // A new pass, as after a relaunch, reads what the index holds and analyzes nothing, and
    // says only that it's done: no "0 of 0".
    let relaunchedHeard = Heard()
    let relaunched = LibraryAnalysis(
        cache: library.cache(),
        analyze: { path in
            heard.ask(path)
            return clean
        }, scanRunning: { false }, report: relaunchedHeard.report)
    #expect(try await relaunched.standing() == .init(paused: nil, everyFileTried: true))
    let again = await relaunched.start().value
    #expect(again.analyzed == 3 && again.total == 3 && again.stage == .finished)
    #expect(relaunchedHeard.progress == [again])
    #expect(heard.paths.isEmpty)
}

/// Analyze Library Again reads every file, keeping each one's measures until its new ones are
/// stored; paused and relaunched, it shows as paused and carries on with what it hadn't read.
@Test func aRunAgainReadsEveryFileAndCarriesOnAfterARelaunch() async throws {
    let library = try ScannedFixtures()
    _ = await LibraryAnalysis(
        cache: library.cache(), scanRunning: { false }, report: { _ in }
    ).start().value
    let heard = Heard()
    let pass = LibraryAnalysis(
        cache: library.cache(),
        analyze: { path in
            heard.ask(path)
            if path == library.paths[1] { try await Task.sleep(nanoseconds: 60_000_000_000) }
            return clean
        }, filesAtOnce: 1, scanRunning: { false }, report: heard.report)
    let run = await pass.start(again: true)
    try await eventually { heard.paths.count == 2 }
    await pass.pause()
    let paused = await run.value
    #expect(paused.stage == .paused && paused.analyzed == 1 && paused.total == 3)
    let index = try LibraryIndex(at: library.databaseURL)
    let rows = try index.rows(ids: try index.trackIDs(sortedBy: .path))
    // The first file's new measures replaced its 16 kHz cutoff; the others keep theirs.
    #expect(rows[0].cutoffHz == nil && rows.allSatisfy { $0.effectiveBits != nil })

    let relaunched = LibraryAnalysis(
        cache: library.cache(),
        analyze: { path in
            heard.ask(path)
            return clean
        }, scanRunning: { false }, report: { _ in })
    let standing = try await relaunched.standing()
    #expect(standing.paused?.text == "Library analysis paused: 1 of 3")
    #expect(!standing.everyFileTried)
    let ended = await relaunched.start().value
    #expect(ended.stage == .finished && ended.analyzed == 3 && ended.total == 3)
    // Read several at once, in either order.
    #expect(heard.paths.dropFirst(2).sorted() == library.paths.dropFirst().sorted())
    #expect(try await relaunched.standing() == .init(paused: nil, everyFileTried: true))
}

/// Two files at once: the second and third take until the run is paused, the first time, so
/// the pause stops both, and the next run reads each of them once more.
@Test func pausingStopsEveryFileUnderWayAndTheNextRunReadsThemAgain() async throws {
    let library = try ScannedFixtures()
    let heard = Heard()
    let pass = LibraryAnalysis(
        cache: library.cache(),
        analyze: { path in
            heard.ask(path)
            if path != library.paths[0], heard.paths.filter({ $0 == path }).count == 1 {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
            return clean
        }, filesAtOnce: 2, scanRunning: { false }, report: heard.report)
    let run = await pass.start()
    try await eventually { heard.paths.count == 3 }
    await pass.pause()
    let paused = await run.value
    #expect(paused.stage == .paused && paused.analyzed == 1 && paused.total == 3)
    #expect(paused.text == "Library analysis paused: 1 of 3")

    let resumed = await pass.start().value
    #expect(resumed.stage == .finished && resumed.analyzed == 3 && resumed.total == 3)
    #expect(heard.paths.prefix(3).sorted() == library.paths)
    #expect(heard.paths.dropFirst(3).sorted() == Array(library.paths.dropFirst()))
}

/// Files under way at a time, and the most there were.
private final class UnderWay: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0
    private var most = 0

    func started() {
        lock.withLock {
            now += 1
            most = max(most, now)
        }
    }
    func ended() { lock.withLock { now -= 1 } }
    var highest: Int { lock.withLock { most } }
}

@Test func aRunAnalyzesSoManyFilesAtOnceStartedInPathOrderEachOnce() async throws {
    #expect((2...4).contains(LibraryAnalysis.filesAtOnce))
    let library = try ScannedFixtures()
    let heard = Heard()
    let underWay = UnderWay()
    let pass = LibraryAnalysis(
        cache: library.cache(),
        analyze: { path in
            underWay.started()
            defer { underWay.ended() }
            heard.ask(path)
            // The first file is slow, so the second and the third overlap it in turn.
            try await Task.sleep(nanoseconds: path == library.paths[0] ? 300_000_000 : 50_000_000)
            return clean
        }, filesAtOnce: 2, scanRunning: { false }, report: heard.report)
    let ended = await pass.start().value
    #expect(ended.stage == .finished && ended.analyzed == 3 && ended.failed == 0)
    #expect(underWay.highest == 2)
    // The first two start together, in either order; the third once the second is done.
    #expect(heard.paths.prefix(2).sorted() == Array(library.paths.prefix(2)))
    #expect(heard.paths.last == library.paths[2] && heard.paths.count == 3)
}

@Test func aRunWaitsWhileAScanRunsAndGoesOnWhenItEnds() async throws {
    let library = try ScannedFixtures()
    let heard = Heard()
    heard.scanRuns = true
    let pass = LibraryAnalysis(
        cache: library.cache(),
        analyze: { path in
            heard.ask(path)
            return clean
        }, scanRunning: { heard.scanRuns }, report: heard.report)
    let run = await pass.start()
    try await eventually { heard.progress.last?.stage == .waitingForScan }
    #expect(heard.progress.last?.text == "Analyzing library: 0 of 3, waiting for the scan")
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(heard.paths.isEmpty)
    heard.scanRuns = false
    let ended = await run.value
    #expect(ended.stage == .finished && ended.analyzed == 3)
    #expect(heard.paths.sorted() == library.paths)
}

/// A store that fails is tried again without reading the file again; one that keeps failing
/// counts as a store failure, not a read.
@Test func aStoreThatFailsIsTriedAgainWithoutAnotherRead() async throws {
    let library = try ScannedFixtures()
    let heard = Heard()
    let cache = library.cache()
    let pass = LibraryAnalysis(
        cache: cache,
        analyze: { path in
            heard.ask(path)
            return clean
        },
        store: { measures, path, stamp in
            heard.ask("store " + path)
            let tries = heard.paths.filter { $0 == "store " + path }.count
            // The first file's first try, and every try for the last.
            if (path == library.paths[0] && tries == 1) || path == library.paths[2] {
                throw SQLiteBusy()
            }
            try await cache.store(measures, path: path, stamp: stamp)
        }, scanRunning: { false }, report: { _ in })
    let ended = await pass.start().value
    #expect(heard.paths.filter { !$0.hasPrefix("store ") }.sorted() == library.paths, "read once")
    #expect(heard.paths.filter { $0 == "store " + library.paths[2] }.count == 3)
    #expect(ended.analyzed == 3 && ended.failed == 1 && ended.unstored == 1)
    #expect(ended.text == "Library analyzed: 3 files, 1 couldn't be stored; the log says why")
    let files = try await cache.analysisFiles()
    #expect(files.pending.isEmpty && files.failed == 1)
}

private struct SQLiteBusy: Error {}

@Test func aFileThatFailsIsCountedAndReadAgainByARunAgain() async throws {
    let library = try ScannedFixtures()
    let heard = Heard()
    let pass = LibraryAnalysis(
        cache: library.cache(),
        analyze: { path in
            heard.ask(path)
            guard path != library.paths[1] else { throw AnalysisError.nonFiniteSample }
            return clean
        }, scanRunning: { false }, report: { _ in })
    let ended = await pass.start().value
    #expect(ended.analyzed == 3 && ended.failed == 1)
    #expect(ended.text == "Library analyzed: 3 files, 1 couldn't be read; the log says why")
    #expect(try await pass.standing() == .init(paused: nil, everyFileTried: true))
    _ = await pass.start(again: true).value
    #expect(heard.paths.filter { $0 == library.paths[1] }.count == 2)
}

/// A run carried on after a pause doesn't read a file that failed before the pause again, and
/// its count goes on from where it stopped, the failure counted.
@Test func aRunCarriedOnKeepsItsFailures() async throws {
    let library = try ScannedFixtures()
    let heard = Heard()
    let pass = LibraryAnalysis(
        cache: library.cache(),
        analyze: { path in
            heard.ask(path)
            if path == library.paths[0] { throw AnalysisError.nonFiniteSample }
            if path == library.paths[1], heard.paths.filter({ $0 == path }).count == 1 {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
            return clean
        }, filesAtOnce: 1, scanRunning: { false }, report: heard.report)
    let run = await pass.start()
    try await eventually { heard.paths.count == 2 }
    await pass.pause()
    let paused = await run.value
    #expect(paused.stage == .paused && paused.analyzed == 1 && paused.total == 3)
    #expect(try await pass.standing().paused?.analyzed == 1)

    let reportsBefore = heard.progress.count
    let resumed = await pass.start().value
    #expect(resumed.stage == .finished && resumed.analyzed == 3 && resumed.total == 3)
    #expect(heard.progress.dropFirst(reportsBefore).first?.analyzed == 1)
    #expect(heard.paths.filter { $0 == library.paths[0] }.count == 1)
}

/// A pause that comes after the last file started, and that the file finishes through, leaves
/// nothing to do: the run ends as finished, not paused.
@Test func aPauseAfterTheLastFileStartedThatItFinishesThroughEndsTheRun() async throws {
    let library = try ScannedFixtures()
    let heard = Heard()
    let pass = LibraryAnalysis(
        cache: library.cache(),
        analyze: { path in
            heard.ask(path)
            // The last file goes on through the pause, as a read under way can.
            while path == library.paths[2], !heard.paths.contains("paused") {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return clean
        }, filesAtOnce: 1, scanRunning: { false }, report: heard.report)
    let run = await pass.start()
    try await eventually { heard.paths.contains(library.paths[2]) }
    await pass.pause()
    heard.ask("paused")
    let ended = await run.value
    #expect(ended.stage == .finished && ended.analyzed == 3 && ended.total == 3)
    #expect(try await pass.standing() == .init(paused: nil, everyFileTried: true))
}
