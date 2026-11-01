import Foundation
import Library
import SQLite
import Settings

/// How many plays the history benchmarks log over the fixture library: about 20 years of a few
/// hours' listening a day.
private let syntheticPlayCount = 1_000_000

let historyBenchmarks = [
    Benchmark(
        name: "history: one timeline page of 200 plays, 1M synthetic plays (p95)",
        budget: Budget(appleSilicon: 5, oldMac: 15, unit: .milliseconds)
    ) {
        let index = try playedLibrary.get().index
        let pageSize = 200
        // Pages from the top down to the oldest, as scrolling reads them, keyed by the last ID.
        let starts: [Int64?] = [nil] + (1...99).map { Int64(syntheticPlayCount / 100 * $0) }
        var missing = 0
        let samples = try millisecondSamples(
            starts.map { start in
                {
                    let page = try index.timeline(before: start, limit: pageSize)
                    guard page.count == pageSize else {
                        throw BenchError.expected("a full page before \(String(describing: start))")
                    }
                    // A page is read with what its rows show, as the timeline draws it.
                    let played = try index.playedTracks(ids: page.map(\.trackID))
                    missing += page.filter { played[$0.trackID]?.track == nil }.count
                }
            })
        return Measured(
            value: p95(samples),
            notes: ["\(samples.count) pages from the newest to the oldest, \(missing) rows missing"]
        )
    },
    Benchmark(
        name: "history: History, one row per track played, 1M synthetic plays (p95)",
        budget: Budget(appleSilicon: 30, oldMac: 80, unit: .milliseconds)
    ) {
        let index = try playedLibrary.get().index
        var count = 0
        let samples = try millisecondSamples(
            (0..<30).map { _ in
                {
                    count = try index.trackIDs(
                        TrackFilter(source: .history), sortedBy: .lastPlayed, ascending: false
                    ).count
                }
            })
        return Measured(value: p95(samples), notes: ["\(count) tracks played"])
    },
    Benchmark(
        name: "history: record a play, 1M synthetic plays (p95)",
        budget: Budget(appleSilicon: 2, oldMac: 6, unit: .milliseconds)
    ) {
        let library = try playedLibrary.get()
        let now = Date().timeIntervalSince1970
        let samples = try millisecondSamples(
            (0..<200).map { offset in
                {
                    try library.index.recordPlay(
                        library.paths[(offset * 7919) % library.paths.count],
                        at: now + Double(offset))
                }
            })
        return Measured(value: p95(samples), notes: ["200 plays, each its own transaction"])
    },
    Benchmark(
        name: "history: history table plus its index, 1M synthetic plays",
        budget: Budget(appleSilicon: 40, oldMac: 40, unit: .megabytes)
    ) {
        let library = try playedLibrary.get()
        let bytes = try library.database.prepare(
            "SELECT sum(pgsize) FROM dbstat WHERE name IN ('history', 'history_path')"
        ).map { try $0.int(0) }[0]
        return Measured(
            value: Double(bytes) / 1e6,
            notes: [
                String(
                    format: "%.1f bytes a play", Double(bytes) / Double(syntheticPlayCount))
            ])
    },
]

/// A copy of the scanned fixture library with `syntheticPlayCount` plays logged, under `.build`
/// so the generated data stays out of git and the user's folders.
private struct PlayedLibrary: @unchecked Sendable {
    var index: LibraryIndex
    /// A second connection, for what `LibraryIndex` doesn't offer, such as page sizes.
    var database: Database
    var paths: [String]
}

private let playedLibrary = Result { () throws -> PlayedLibrary in
    let source = try scannedLibrary.get().databaseURL
    let directory = try buildDirectory().appendingPathComponent("bench-plays")
    if FileManager.default.fileExists(atPath: directory.path) {
        try FileManager.default.removeItem(at: directory)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let databaseURL = libraryFileURL(in: directory)
    for suffix in ["", Database.walSuffix]
    where FileManager.default.fileExists(atPath: source.path + suffix) {
        try FileManager.default.copyItem(
            atPath: source.path + suffix, toPath: databaseURL.path + suffix)
    }
    let index = try LibraryIndex(at: databaseURL)
    let rows = try index.rows(ids: try index.trackIDs(sortedBy: .path))
    let database = try Database(at: databaseURL)
    // Written straight to the tables: a million transactions through recordPlay would take
    // minutes. A few tracks are played far more often than most, as in a real library.
    try database.transaction {
        let insert = try database.prepare(insertHistorySQL)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        let start = Int(Date().timeIntervalSince1970) - syntheticPlayCount * 600
        for play in 0..<syntheticPlayCount {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let draw = Double(state >> 11) / Double(1 << 53)
            let row = Int(draw * draw * Double(rows.count))
            try insert.run(rows[row].id, start + play * 600)
        }
        try database.execute(
            """
            INSERT INTO plays (path_id, play_count, skip_count, last_played_seconds)
            SELECT path_id, count(*), 0, max(played_at) FROM history GROUP BY path_id
            """)
    }
    try index.checkpoint()
    return PlayedLibrary(index: index, database: database, paths: rows.map(\.path))
}

/// The `.build` folder the Bench binary was built into.
private func buildDirectory() throws -> URL {
    var url = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    while url.pathComponents.count > 1 {
        url.deleteLastPathComponent()
        if url.lastPathComponent == ".build" { return url }
    }
    throw BenchError.expected("Bench to run from inside a .build folder")
}
