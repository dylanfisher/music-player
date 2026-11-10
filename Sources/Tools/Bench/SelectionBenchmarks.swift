import Foundation
import Library
import LibraryBrowser
import Metadata
import TagEditor

/// Fixture files Get Info's read is timed on, to give its cost a file for a whole selection.
private let editorSampleFiles = 500

/// ⌘A over the whole fixture library, then what each command does with it before anything
/// shows, through the browser model and reader the window uses (phase 32e).
let selectionBenchmarks = [
    Benchmark(
        name: "selection: every fixture track selected, Play Next to the files queued",
        budget: Budget(appleSilicon: 200, oldMac: 600, unit: .milliseconds)
    ) {
        try selectionMeasured(prepare: { _ in 0 }) { model, rows, _ in
            _ = try await model.urls(ofRows: rows)
        }
    },
    Benchmark(
        name: "selection: every fixture track selected, Add to Playlist",
        budget: Budget(appleSilicon: 200, oldMac: 1500, unit: .milliseconds)
    ) {
        try selectionMeasured(
            prepare: { try LibraryIndex(at: $0).createPlaylist(named: "Everything") }
        ) { model, rows, playlist in
            _ = try await model.add(model.ids(ofRows: rows), to: playlist)
        }
    },
    Benchmark(
        name: "selection: every fixture track selected, Get Info's read per file",
        budget: Budget(appleSilicon: 0.12, oldMac: 4, unit: .milliseconds)
    ) {
        let index = try LibraryIndex(at: try scannedLibrary.get().databaseURL)
        let paths = try index.paths(ids: try index.trackIDs(sortedBy: .artist))
        let sample = Array(paths.values.sorted().prefix(editorSampleFiles))
        var read: (tracks: [EditableTrack], problems: [String])?
        let elapsed = seconds { read = readEditableTracks(sample) }
        guard let read, !read.tracks.isEmpty else {
            throw BenchError.expected("the sample files read")
        }
        let perFileMs = elapsed * 1000 / Double(sample.count)
        return Measured(
            value: perFileMs,
            notes: [
                "\(sample.count) files, \(filesReadAtOnce) at once; all \(paths.count) would take"
                    + String(
                        format: " %.1f s before the editor opens",
                        perFileMs * Double(paths.count) / 1000)
            ])
    },
]

/// The keys type-to-select's row types, each a new query a second after the last: every
/// letter, and two no title starts with, which read every row.
private let typedSelections = "abcdefghijklmnopqrstuvwxyz".map(String.init) + ["qx", "zq"]

/// Type-to-select over every fixture track sorted by title, a key at a time, from the key to
/// the row found, as the track table finds it: the list's texts, folded once per list and kept,
/// then the first that starts with the query. The fold is timed apart, once.
let typeSelectBenchmarks = [
    Benchmark(
        name: "selection: type-to-select a key over every fixture title, sorted by title (p95)",
        budget: Budget(appleSilicon: 20, oldMac: 80, unit: .milliseconds)
    ) {
        let databaseURL = try scannedLibrary.get().databaseURL
        let (foldMs, samples) = try onMainActor {
            let model = try await loadedModel(databaseURL)
            await model.setSort(.title, ascending: true)
            _ = try await model.trackNames()
            let folding = DispatchTime.now().uptimeNanoseconds
            _ = try await model.typeSelectTexts()
            let foldMs = Double(DispatchTime.now().uptimeNanoseconds - folding) / 1e6
            var samples: [Double] = []
            for query in typedSelections {
                let start = DispatchTime.now().uptimeNanoseconds
                let texts = try await model.typeSelectTexts()
                _ = TypeSelect.firstIndex(startingWith: query, inFolded: texts)
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            return (foldMs, samples)
        }
        return Measured(
            value: p95(samples),
            notes: [
                slowestNote(samples),
                String(format: "the list's texts folded once first, %.1f ms", foldMs),
            ])
    }
]

/// Milliseconds from ⌘A's selection of every row to the end of `body`, on a copy of the
/// fixture index that `prepare` readies first, the median of three.
private func selectionMeasured<T: Sendable>(
    prepare: @escaping (URL) throws -> T,
    _ body: @escaping @MainActor (BrowserModel, IndexSet, T) async throws -> Void
) throws -> Measured {
    let samples = try (0..<3).map { run in
        try withLibraryCopy("selection-\(run)") { databaseURL in
            let prepared = try prepare(databaseURL)
            return try onMainActor {
                let model = try await loadedModel(databaseURL)
                let rows = IndexSet(model.trackIDs.indices)
                let start = DispatchTime.now().uptimeNanoseconds
                try await body(model, rows, prepared)
                return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            }
        }
    }
    return Measured(
        value: samples.sorted()[1],
        notes: ["each run " + samples.map { String(format: "%.1f ms", $0) }.joined(separator: ", ")]
    )
}
