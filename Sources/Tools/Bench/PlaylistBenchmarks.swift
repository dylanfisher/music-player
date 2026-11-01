import Foundation
import Library
import SQLite
import Settings

let playlistBenchmarks = [
    Benchmark(
        name: "playlists: list a smart playlist of six rules over every fixture track (p95)",
        budget: Budget(appleSilicon: 50, oldMac: 150, unit: .milliseconds)
    ) {
        let source = try scannedLibrary.get().databaseURL
        return try withScratchDirectory("smart-playlist") { directory in
            // A copy, so the plays and ratings written here don't reach the other benchmarks.
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let databaseURL = libraryFileURL(in: directory)
            for suffix in ["", Database.walSuffix]
            where FileManager.default.fileExists(atPath: source.path + suffix) {
                try FileManager.default.copyItem(
                    atPath: source.path + suffix, toPath: databaseURL.path + suffix)
            }
            let index = try LibraryIndex(at: databaseURL)
            let rows = try index.rows(ids: try index.trackIDs(sortedBy: .path))
            let paths = rows.map(\.path)
            let now = Date().timeIntervalSince1970
            // A third of the library played, a fifth rated, as a library in use would be.
            for (offset, path) in paths.enumerated() where offset % 3 == 0 {
                try index.recordPlay(path, at: now - Double(offset) * 60)
            }
            for stars in 1...5 {
                try index.setRating(
                    stars,
                    trackIDs: rows.enumerated().filter { $0.offset % 25 == stars }.map(\.element.id)
                )
            }
            let rules = SmartRules(
                match: .all,
                rules: [
                    SmartRule(.genre, .isNot, .text("Spoken Word")),
                    SmartRule(.title, .doesNotContain, .text("interlude")),
                    SmartRule(.year, .greaterThan, .number(1960)),
                    SmartRule(.duration, .lessThan, .number(1200)),
                    SmartRule(.playCount, .lessThan, .number(50)),
                    SmartRule(.lastPlayed, .notInLast, .number(1)),
                ], limit: SmartLimit(count: 1000, order: .mostPlayed))
            let id = try index.createPlaylist(named: "Bench", rules: rules)
            let filter = TrackFilter(source: .playlist(id))
            var count = 0
            let samples = try millisecondSamples(
                (0..<30).map { _ in
                    { count = try index.trackIDs(filter, sortedBy: .artist).count }
                })
            return Measured(
                value: p95(samples),
                notes: ["\(count) of \(paths.count) tracks match, limited to 1000 by plays"])
        }
    }
]
