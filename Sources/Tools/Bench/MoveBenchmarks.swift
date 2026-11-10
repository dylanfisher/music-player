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
    },
    Benchmark(
        name:
            "library: Organize Selected Files over about \(organizedFileCount) fixture files in a"
            + " library folder of every fixture artist, plan and move, local",
        budget: Budget(appleSilicon: 15, oldMac: 60, unit: .seconds)
    ) {
        try organizeRun()
    },
]

/// About how many files Organize Selected Files' row moves: the first fixture artists' whole
/// folders, enough to reach it.
private let organizedFileCount = 2_000

/// Organize Selected Files as the browser runs it once the user confirms: the plan of where
/// each file goes by its tags, then its moves, each file checked again first (ADR 0164). The
/// files are clones of the first fixture artists' folders, beside an empty folder for each other
/// fixture artist, so the library folder lists as the fixture library does; the fixture
/// layout isn't the library folder's, so every file moves.
private func organizeRun() throws -> Measured {
    let root = try defaultFixturesDirectory()
    _ = try generateFixtures(count: fullLibraryFileCount, in: root)
    let byArtist = Dictionary(
        grouping: try loadManifest(in: root).files.filter { $0.malformation == nil }
    ) { String($0.path.prefix { $0 != "/" }) }
    return try withScratchDirectory("organize") { directory in
        let library = directory.appendingPathComponent("library folder", isDirectory: true)
        var paths: [String] = []
        var cloned = 0
        for artist in byArtist.keys.sorted() {
            let folder = library.appendingPathComponent(artist, isDirectory: true)
            if paths.count < organizedFileCount {
                try FileManager.default.createDirectory(
                    at: library, withIntermediateDirectories: true)
                // A clone, which on APFS costs no copy of the audio.
                try FileManager.default.copyItem(
                    at: root.appendingPathComponent(artist, isDirectory: true), to: folder)
                paths += byArtist[artist]!.map { library.path + "/" + $0.path }
                cloned += 1
            } else {
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true)
            }
        }
        let ledger = libraryFileURL(in: directory)
        _ = try LibraryIndex(at: ledger)
        var planned: FilesOrganized?
        let planSeconds = seconds { planned = layoutMoves(paths, libraryFolder: library.path) }
        guard let plan = planned, plan.moved.count == paths.count, plan.problems.isEmpty else {
            throw BenchError.expected(
                "every one of \(paths.count) files to move: \(String(describing: planned))")
        }
        var moved: FilesOrganized?
        let moveSeconds = seconds {
            moved = moveToLayout(
                plan, libraryFolder: library.path, checkingAgain: true, ledger: ledger,
                progress: { _ in })
        }
        guard let done = moved, done.moved.count == plan.moved.count, done.problems.isEmpty
        else {
            throw BenchError.expected(
                "every planned file moved: \(String(describing: moved?.problems.prefix(3)))")
        }
        return Measured(
            value: planSeconds + moveSeconds,
            notes: [
                String(
                    format: "%d files of %d artists: the plan %.2f s, the moves %.2f s;"
                        + " %.2f ms a file",
                    paths.count, cloned, planSeconds, moveSeconds,
                    (planSeconds + moveSeconds) * 1000 / Double(paths.count))
            ])
    }
}
