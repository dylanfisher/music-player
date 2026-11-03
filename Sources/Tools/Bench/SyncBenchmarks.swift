import Fixtures
import Foundation
import Library
import Settings

/// Plays in the synthetic log, as many as `historyBenchmarks` record.
private let syncedPlays = 1_000_000
/// Tracks they're spread over, about the fixture library's count.
private let syncedTracks = 43_000

let syncBenchmarks = [
    Benchmark(
        name: "sync: merge 1M play events from another machine's log",
        budget: Budget(appleSilicon: 20, oldMac: 120, unit: .seconds)
    ) {
        let directory = try emptyCacheDirectory("bench-sync")
        let sync = directory.appendingPathComponent("sync")
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        let share = "smb://bench/music"
        let index = try LibraryIndex(at: libraryFileURL(in: directory))
        _ = try index.locate(
            [WatchedFolder(path: "library", share: share, kind: .network)],
            among: [MountedShare(url: share, mountPoint: directory.path + "/music")])
        let log = try writeOtherMachinesLog(in: sync)
        let bytes = try FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int ?? 0

        var report: SyncReport?
        let elapsed = try seconds { report = try index.sync(folder: "bench", at: sync.path) }
        guard let report, report.applied == syncedPlays, report.problems.isEmpty else {
            throw BenchError.expected(
                "\(syncedPlays) plays applied without problems: \(String(describing: report))")
        }
        let history = try index.loggedPlayCount()
        try FileManager.default.removeItem(at: directory)
        return Measured(
            value: elapsed,
            notes: [
                String(
                    format: "log %.0f MB, %.0f events a second", Double(bytes) / 1e6,
                    Double(syncedPlays) / elapsed),
                "\(history) plays in the history",
            ])
    },
    Benchmark(
        name: "sync: launch to the first scan's start, a 1M-event merge pending",
        budget: Budget(appleSilicon: 1, oldMac: 3, unit: .seconds)
    ) {
        let library = try scannedLibrary.get()
        let directory = try emptyCacheDirectory("bench-launch-sync")
        let sync = directory.appendingPathComponent("sync")
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        let databaseURL = libraryFileURL(in: directory)
        try FileManager.default.copyItem(at: library.databaseURL, to: databaseURL)
        _ = try writeOtherMachinesLog(in: sync)

        let events = LaunchEvents()
        let watcher = LibraryWatcher(
            databaseURL: databaseURL, networkReaders: nil, events: events.heard)
        let start = DispatchTime.now().uptimeNanoseconds
        watcher.start(
            folders: [library.folder], syncFolder: SyncFolder(path: sync.path),
            rescanNetworkFoldersAtLaunch: false, pausePollingDuringPlayback: false)
        let ended = events.ended.wait(timeout: .now() + launchSyncDeadlineSeconds)
        watcher.stop()
        try FileManager.default.removeItem(at: directory)
        guard ended == .success else {
            throw BenchError.expected(
                "the launch scan and a sync after it to end within \(launchSyncDeadlineSeconds) s")
        }
        let (scanStarted, merged, failure) = events.seen
        guard let scanStarted, let merged, failure == nil else {
            throw BenchError.expected(
                "a scan and the merge without failures: \(failure ?? "no scan or no merge")")
        }
        func seconds(_ at: UInt64) -> Double { Double(at - start) / 1e9 }
        return Measured(
            value: seconds(scanStarted),
            notes: [String(format: "the merge ended at %.1f s", seconds(merged))])
    },
]

/// How long the launch benchmark waits for the scan and the syncs.
private let launchSyncDeadlineSeconds = 300.0

/// When a watcher's first scan started and its merge of the other machine's plays ended, from
/// its events.
private final class LaunchEvents: @unchecked Sendable {
    // Every field but `ended` is guarded by `lock`.
    private let lock = NSLock()
    private var scanStarted: UInt64?
    private var merged: UInt64?
    private var scanned = false
    private var failure: String?
    /// Signalled once a sync ended after the launch scans did, so nothing is left running on
    /// the database, or once something failed.
    let ended = DispatchSemaphore(value: 0)

    var seen: (scanStarted: UInt64?, merged: UInt64?, failure: String?) {
        lock.withLock { (scanStarted, merged, failure) }
    }

    func heard(_ event: WatcherEvent) {
        let now = DispatchTime.now().uptimeNanoseconds
        let done = lock.withLock { () -> Bool in
            switch event {
            case .scanning:
                if scanStarted == nil { scanStarted = now }
                return false
            case .launchScansEnded:
                scanned = true
                return false
            case .synced(let report):
                if report.applied > 0 { merged = now }
                return scanned
            case .scanFailed(_, let reason), .syncFailed(let reason):
                let first = failure == nil
                failure = reason
                return first
            default: return false
            }
        }
        if done { ended.signal() }
    }
}

/// Writes another machine's log of `syncedPlays` plays over `syncedTracks` tracks into `sync`,
/// and returns its URL. Written straight to the file: a million transactions on a second
/// library would take minutes. A few tracks are played far more often than most, as in a real
/// library.
func writeOtherMachinesLog(in sync: URL) throws -> URL {
    let log = sync.appendingPathComponent(syncLogName(String(repeating: "ab", count: 16)))
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let handle = try FileHandle(forWritingTo: log)
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    let start = Date().timeIntervalSince1970 - Double(syncedPlays) * 600
    var chunk = ""
    for play in 0..<syncedPlays {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let draw = Double(state >> 11) / Double(1 << 53)
        let track = Int(draw * draw * Double(syncedTracks))
        let at = start + Double(play) * 600
        chunk +=
            SyncRecord.playLine(
                seq: Int64(play + 1), ms: Int64(at * 1000),
                path: "music/library/Artist \(track / 120)/Album \(track / 12)/\(track) Title.flac",
                at: at) + "\n"
        if chunk.utf8.count > 1 << 20 {
            handle.write(Data(chunk.utf8))
            chunk = ""
        }
    }
    handle.write(Data(chunk.utf8))
    try handle.close()
    return log
}
