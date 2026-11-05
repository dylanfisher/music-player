import AppKit
import Fixtures
import Foundation
import Library
import Metadata
import Settings
import TagEditor
import TagWriter

/// Files the tag editor opens on, as when an artist's albums are selected.
private let editedFileCount = 200
/// The opens the editor makes for one track: the tags, the art and the fields holding several
/// values all come through one.
private let opensPerEditedFile = 1
/// Get Info on an album and a half's worth of tracks.
private let infoWindowFileCount = 100
/// Runs each Get Info and write benchmark takes the median of.
private let editorRuns = 5

let tagEditorBenchmarks = [
    Benchmark(
        name: "tag editor: read \(editedFileCount) fixture files on the slow simulated NAS",
        budget: Budget(appleSilicon: 5, oldMac: 15, unit: .seconds)
    ) {
        let paths = try fixturePaths(editedFileCount, readableOnly: false)
        var read: (tracks: [EditableTrack], problems: [String])?
        let elapsed = seconds {
            read = readEditableTracks(
                paths,
                read: { path in
                    // Each open costs what an art read does on the slow NAS (ADR 0073).
                    Thread.sleep(forTimeInterval: Double(opensPerEditedFile) * nasArtReadSeconds)
                    return try readEditableTrack(path)
                })
        }
        guard let read, !read.tracks.isEmpty else { throw BenchError.expected("tracks read") }
        return Measured(
            value: elapsed,
            notes: [
                "\(read.tracks.count) read, \(read.problems.count) the editor can't open;"
                    + String(
                        format: " %.0f ms a file's opens on the NAS",
                        Double(opensPerEditedFile) * nasArtReadSeconds * 1000)
            ])
    },
    Benchmark(
        name: "Get Info: one fixture track, to its window on screen (median of \(editorRuns))",
        budget: Budget(appleSilicon: 50, oldMac: 150, unit: .milliseconds)
    ) {
        let runs = try getInfoRuns(1)
        return Measured(value: median(runs.map(\.shownMs)), notes: [runsNote(runs.map(\.shownMs))])
    },
    Benchmark(
        name: "Get Info: one fixture track, to its fields (median of \(editorRuns))",
        budget: Budget(appleSilicon: 100, oldMac: 300, unit: .milliseconds)
    ) {
        let runs = try getInfoRuns(1)
        return Measured(
            value: median(runs.map(\.filledMs)), notes: [runsNote(runs.map(\.filledMs))])
    },
    Benchmark(
        name:
            "Get Info: \(infoWindowFileCount) fixture tracks, to their fields (median of \(editorRuns))",
        budget: Budget(appleSilicon: 500, oldMac: 2000, unit: .milliseconds)
    ) {
        let runs = try getInfoRuns(infoWindowFileCount)
        return Measured(
            value: median(runs.map(\.filledMs)),
            notes: [
                runsNote(runs.map(\.filledMs))
                    + String(format: "; the window showed in %.1f ms", median(runs.map(\.shownMs)))
            ])
    },
    Benchmark(
        name:
            "tag write: one fixture FLAC's title, written and read back into the index (median of \(editorRuns))",
        budget: Budget(appleSilicon: 100, oldMac: 400, unit: .milliseconds)
    ) {
        let (write, rescan) = try writeAndRescanRuns()
        let total = zip(write, rescan).map { $0 + $1 }
        return Measured(
            value: median(total),
            notes: [
                runsNote(total)
                    + String(
                        format: "; the write %.1f ms, the rescan %.1f ms", median(write),
                        median(rescan))
            ])
    },
]

/// The first `count` fixture files of the full library, by absolute path; with `readableOnly`,
/// none made malformed.
private func fixturePaths(_ count: Int, readableOnly: Bool = true) throws -> [String] {
    let root = try defaultFixturesDirectory()
    _ = try generateFixtures(count: fullLibraryFileCount, in: root)
    let files = try loadManifest(in: root).files
    return files.filter { !readableOnly || $0.malformation == nil }.prefix(count).map {
        root.appendingPathComponent($0.path).path
    }
}

private struct GetInfoRun: Sendable {
    var shownMs: Double
    var filledMs: Double
}

/// Get Info on `count` fixture files through the app's `TagEditing`, each run timed from the
/// command to the window on screen and to its fields filled in from the files.
private func getInfoRuns(_ count: Int) throws -> [GetInfoRun] {
    let paths = try fixturePaths(count)
    let journal = try emptyCacheDirectory("bench-get-info")
    return try onMainActor {
        let editing = TagEditing(writer: TagWriter(journal: TagUndoJournal(dataDirectory: journal)))
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
            backing: .buffered, defer: false)
        var runs: [GetInfoRun] = []
        // One untimed run first, as `medianMilliseconds` does.
        for run in 0...editorRuns {
            let start = DispatchTime.now().uptimeNanoseconds
            editing.open(paths, over: parent)
            guard let editor = editing.editors.last, editor.window.isVisible else {
                throw BenchError.expected("the info window on screen")
            }
            let shown = DispatchTime.now().uptimeNanoseconds
            while !editor.isLoaded { try await Task.sleep(nanoseconds: 500_000) }
            editor.window.displayIfNeeded()
            let filled = DispatchTime.now().uptimeNanoseconds
            editor.window.close()
            if run > 0 {
                runs.append(
                    GetInfoRun(
                        shownMs: Double(shown - start) / 1e6,
                        filledMs: Double(filled - start) / 1e6))
            }
        }
        return runs
    }
}

/// A fixture FLAC copied into a folder of its own and indexed, then its title written through
/// `TagWriter` and read back through `LibraryScanner.rescan(files:)`, as Save does: the write
/// and the rescan of each run, in milliseconds.
private func writeAndRescanRuns() throws -> (write: [Double], rescan: [Double]) {
    let root = try defaultFixturesDirectory()
    _ = try generateFixtures(count: fullLibraryFileCount, in: root)
    let flac = try loadManifest(in: root).files.first {
        $0.container == .flac && $0.malformation == nil
    }
    guard let flac else { throw BenchError.expected("a fixture FLAC") }
    let directory = try emptyCacheDirectory("bench-tag-write")
    let music = directory.appendingPathComponent("Music", isDirectory: true)
    try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
    let path = music.appendingPathComponent("track.flac", isDirectory: false).path
    try FileManager.default.copyItem(atPath: root.appendingPathComponent(flac.path).path, toPath: path)
    let scanner = LibraryScanner(
        databaseURL: directory.appendingPathComponent("library.sqlite", isDirectory: false))
    _ = try scanner.scan(WatchedFolder(path: music.path, kind: .local))
    let writer = TagWriter(
        journal: TagUndoJournal(dataDirectory: directory.appendingPathComponent("data")))
    var write: [Double] = []
    var rescan: [Double] = []
    for run in 0...editorRuns {
        let start = DispatchTime.now().uptimeNanoseconds
        let report = writer.write(TagEdit(values: [.title: "Bench \(run)"]), to: [path])
        guard report.changed == [path] else {
            throw BenchError.expected("the title written: \(report.failures)")
        }
        let written = DispatchTime.now().uptimeNanoseconds
        guard try scanner.rescan(files: [path]).read == 1 else {
            throw BenchError.expected("the file read again")
        }
        let read = DispatchTime.now().uptimeNanoseconds
        if run > 0 {
            write.append(Double(written - start) / 1e6)
            rescan.append(Double(read - written) / 1e6)
        }
    }
    try FileManager.default.removeItem(at: directory)
    return (write, rescan)
}

private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

private func runsNote(_ values: [Double]) -> String {
    "each run: " + values.map { String(format: "%.1f ms", $0) }.joined(separator: ", ")
}
