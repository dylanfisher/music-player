import Analysis
import Fixtures
import Foundation
import Library
import Settings

let moveBenchmarks = [
    Benchmark(
        name: "library: rescan after renaming every fixture file, matching each move",
        budget: Budget(appleSilicon: 10, oldMac: 240, unit: .seconds)
    ) {
        // A clone of the fixture library, which on APFS costs no copy of the audio.
        let fixtures = try defaultFixturesDirectory()
        let directory = try emptyCacheDirectory("bench-moves")
        let root = directory.appendingPathComponent("renamed")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtures, to: root)
        let databaseURL = libraryFileURL(in: directory)
        let folder = WatchedFolder(path: root.path, kind: .local)
        let scanner = LibraryScanner(databaseURL: databaseURL)
        _ = try scanner.scan(folder)
        // Moves keep stats, so every track gets some.
        let index = try LibraryIndex(at: databaseURL)
        let tracks = try index.trackIDs(TrackFilter(), sortedBy: .title, ascending: true)
        try index.setRating(1, trackIDs: tracks)
        let files = FileManager.default.enumerator(atPath: root.path)?.compactMap {
            $0 as? String
        }.filter { audioFileExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
        for file in files ?? [] {
            let path = root.path + "/" + file
            try FileManager.default.moveItem(
                atPath: path,
                toPath: (path as NSString).deletingPathExtension + " renamed."
                    + (path as NSString).pathExtension)
        }

        var rescanned: ScanSummary?
        let elapsed = try seconds { rescanned = try scanner.scan(folder) }
        // The report runs after the scan, over every move left ambiguous.
        var report: HealthReport?
        let reportSeconds = try seconds {
            report = try index.healthReport(measuredChecks: healthChecks)
        }
        let lost = report?[.lostStats].otherCount ?? 0
        guard let summary = rescanned, summary.moved > 0, summary.moved + lost == tracks.count
        else {
            throw BenchError.expected(
                "each of \(tracks.count) tracks to move or be lost:"
                    + " \(String(describing: rescanned)), \(lost) lost")
        }
        try FileManager.default.removeItem(at: directory)
        return Measured(
            value: elapsed,
            notes: [
                "\(summary.read) files read again, \(summary.moved) moves matched,"
                    + " \(lost) left for Lost Stats as ambiguous: the fixtures share few lengths",
                String(format: "health report after it %.2f s", reportSeconds),
            ])
    }
]
