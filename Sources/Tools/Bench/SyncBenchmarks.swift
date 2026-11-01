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
        let directory = try defaultFixturesDirectory().deletingLastPathComponent()
            .appendingPathComponent("bench-sync")
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        let sync = directory.appendingPathComponent("sync")
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        let share = "smb://bench/music"
        let index = try LibraryIndex(at: libraryFileURL(in: directory))
        _ = try index.locate(
            [WatchedFolder(path: "library", share: share, kind: .network)],
            among: [MountedShare(url: share, mountPoint: directory.path + "/music")])
        // Written straight to the file: a million transactions on a second library would take
        // minutes. A few tracks are played far more often than most, as in a real library.
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
                    path:
                        "music/library/Artist \(track / 120)/Album \(track / 12)/\(track) Title.flac",
                    at: at) + "\n"
            if chunk.utf8.count > 1 << 20 {
                handle.write(Data(chunk.utf8))
                chunk = ""
            }
        }
        handle.write(Data(chunk.utf8))
        try handle.close()
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
    }
]
