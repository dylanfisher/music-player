import Foundation
import Testing

@testable import Fixtures
@testable import Library
@testable import Metadata
@testable import Settings

/// Records when each listing ends and each read starts, with listings slowed down so the walk
/// takes long enough to overlap with reading.
private final class RecordingAccess: ScanFileAccess, @unchecked Sendable {
    // Guarded by `lock`.
    private let lock = NSLock()
    private(set) var listingsEnded: [UInt64] = []
    private(set) var readsStarted: [UInt64] = []

    func volumeIsLocal(_ path: String) throws -> Bool? { true }

    func contentsOfDirectory(_ directory: String, keys: [URLResourceKey]) throws -> [URL] {
        usleep(20_000)
        let entries = try SystemFileAccess().contentsOfDirectory(directory, keys: keys)
        lock.withLock { listingsEnded.append(DispatchTime.now().uptimeNanoseconds) }
        return entries
    }

    func readMetadata(at path: String) throws(MetadataError) -> ParsedFile {
        lock.withLock { readsStarted.append(DispatchTime.now().uptimeNanoseconds) }
        return try SystemFileAccess().readMetadata(at: path)
    }
}

/// `count` empty audio files in folders of 20, which every read fails on quickly.
private func emptyFiles(_ count: Int) throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pipeline-\(UUID().uuidString)").path
    for number in 0..<count {
        let directory = root + "/Album \(number / 20)"
        if number % 20 == 0 {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true)
        }
        #expect(
            FileManager.default.createFile(atPath: directory + "/\(number).flac", contents: nil))
    }
    return root
}

@Test func readingStartsBeforeTheWalkFinishes() throws {
    // More folders than listers, so the walk takes several rounds of listings.
    let root = try emptyFiles(20 * 4 * ScanPipeline.listers)
    let access = RecordingAccess()
    let summary = try LibraryScanner(
        databaseURL: URL(fileURLWithPath: root + ".sqlite"), access: access
    ).scan(WatchedFolder(path: root, kind: .local))
    #expect(summary.read == 20 * 4 * ScanPipeline.listers)
    let firstRead = try #require(access.readsStarted.min())
    let lastListing = try #require(access.listingsEnded.max())
    #expect(firstRead < lastListing)
}

@Test func fixedNetworkReadersAreHonored() throws {
    let library = try TestLibrary()
    let nas = SimulatedNAS(
        operationSeconds: 0.002, listingSeconds: 0.002, capacity: 64, fileDelay: nil)
    let summary = try LibraryScanner(
        databaseURL: library.databaseURL, networkReaders: 3, access: nas
    ).scan(WatchedFolder(path: library.root, kind: .network))
    #expect(summary.read == library.manifest.files.count)
    #expect(summary.readers == .fixed(3))
    #expect(nas.mostFilesReadAtOnce == 3)
    let cost = summary.readCost
    #expect(cost.files == summary.read - summary.failed)
    #expect(cost.bytes > 0 && cost.calls >= cost.files)
    #expect(cost.fileSeconds > cost.openSeconds + cost.readSeconds)
    // Fixed readers aren't tuned, so no window is measured.
    #expect(summary.windows == ScanSummary.Windows())
}

@Test func aSimulatedNASDelaysEachFileByItsDiskDelay() throws {
    let root = try emptyFiles(20)
    let path = root + "/Album 0/0.flac"
    func seconds(_ fileDelay: SimulatedNAS.FileDelay?) -> Double {
        let nas = SimulatedNAS(
            operationSeconds: 0, listingSeconds: 0, capacity: 1, fileDelay: fileDelay)
        let started = DispatchTime.now().uptimeNanoseconds
        #expect(throws: MetadataError.self) { try nas.readMetadata(at: path) }
        return Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
    }
    // With no spread, every file waits the median.
    #expect(seconds(.init(medianSeconds: 0.05, sigma: 0)) >= 0.05)
    #expect(seconds(nil) < 0.05)
    #expect(SimulatedNAS.FileDelay(medianSeconds: 0.01, sigma: 1).meanSeconds > 0.016)
}

@Test func progressShowsWhereTheScanIsWaiting() async throws {
    let library = try TestLibrary()
    let (stream, continuation) = AsyncStream.makeStream(
        of: ScanProgress.self, bufferingPolicy: .unbounded)
    // Slow listings, so readers wait for the walk.
    let nas = SimulatedNAS(
        operationSeconds: 0.001, listingSeconds: 0.02, capacity: 64, fileDelay: nil)
    let summary = try LibraryScanner(
        databaseURL: library.databaseURL, networkReaders: 3, access: nas
    ).scan(WatchedFolder(path: library.root, kind: .network), progress: continuation)
    #expect(summary.idleReaderSeconds > 0)
    continuation.finish()
    var loads: [ScanProgress.Load] = []
    for await progress in stream { loads.append(progress.load) }
    #expect(loads.allSatisfy { $0.readers == 3 })
    #expect(loads.contains { $0.listers > 0 })
    #expect(loads.contains { $0.queued > 0 })
    #expect(loads.contains { $0.idleReaders > 0 })
    #expect(loads.last == ScanProgress.Load(readers: 3, idleReaders: 0, listers: 0, queued: 0))
}

@Test func networkReadersClimbMidScanOnASlowNAS() throws {
    // Enough files that the scan outlasts the first window, at 16 readers, by a second or so.
    let count = 2500
    let root = try emptyFiles(count)
    let databaseURL = URL(fileURLWithPath: root + ".sqlite")
    let nas = SimulatedNAS(
        operationSeconds: 0.01, listingSeconds: 0.01, capacity: 64, fileDelay: nil)
    let summary = try LibraryScanner(databaseURL: databaseURL, access: nas)
        .scan(WatchedFolder(path: root, kind: .network))
    #expect(summary.read == count)
    #expect(summary.failed == count)
    guard case .tuned(let levels, _) = summary.readers else {
        Issue.record("expected tuned readers, got \(String(describing: summary.readers))")
        return
    }
    #expect(levels.starts(with: [ReadConcurrency.networkStart, 2 * ReadConcurrency.networkStart]))
    #expect(nas.mostFilesReadAtOnce >= 2 * ReadConcurrency.networkStart)
    #expect(summary.windows.judged >= levels.count - 1)
}

@Test func aPauseIsNeverMeasuredInAWindow() {
    let control = ScanControl()
    var window = ScanPipeline.Window(start: 0, pauseChanges: control.pauseState.changes)
    window.files = 10
    window.seconds = 1
    let second: UInt64 = 1_000_000_000
    #expect(window.measurement(at: second, pause: control.pauseState) != nil)

    // Closing while paused.
    control.pause()
    #expect(window.measurement(at: second, pause: control.pauseState) == nil)

    // The window that began during the pause and ends after the resume includes the pause.
    var after = ScanPipeline.Window(start: 0, pauseChanges: control.pauseState.changes)
    after.files = 10
    after.seconds = 1
    control.resume()
    #expect(after.measurement(at: second, pause: control.pauseState) == nil)

    // The next one is clean.
    var clean = ScanPipeline.Window(start: 0, pauseChanges: control.pauseState.changes)
    clean.files = 10
    clean.seconds = 1
    #expect(clean.measurement(at: second, pause: control.pauseState) != nil)
}

@Test func noReadersStartOnceThereIsNothingLeftToRead() {
    func spawned(stopped: Bool = false, walkFinished: Bool = false, queued: Int = 0) -> Int {
        ScanPipeline.readersToSpawn(
            running: 2, limit: 5, stopped: stopped, walkFinished: walkFinished, queued: queued)
    }
    #expect(spawned() == 3)
    #expect(spawned(stopped: true, queued: 9) == 0)
    #expect(spawned(walkFinished: true) == 0)
    #expect(spawned(walkFinished: true, queued: 1) == 3)
}
