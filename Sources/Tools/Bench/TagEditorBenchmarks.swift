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
            "tag write: one fixture FLAC's title, written in place and read back into the index (median of \(editorRuns))",
        budget: Budget(appleSilicon: 100, oldMac: 400, unit: .milliseconds)
    ) {
        try writeAndRescan(inPlace: true)
    },
    Benchmark(
        name:
            "tag write: one fixture FLAC's title, written through a temp file and read back into the index (median of \(editorRuns))",
        budget: Budget(appleSilicon: 100, oldMac: 400, unit: .milliseconds)
    ) {
        try writeAndRescan(inPlace: false)
    },
]

private func writeAndRescan(inPlace: Bool) throws -> Measured {
    let (write, rescan) = try writeAndRescanRuns(inPlace: inPlace)
    let total = zip(write, rescan).map { $0 + $1 }
    return Measured(
        value: median(total),
        notes: [
            runsNote(total)
                + String(
                    format: "; the write %.1f ms, the rescan %.1f ms", median(write),
                    median(rescan))
        ])
}

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
/// and the rescan of each run, in milliseconds. The title fits the FLAC's padding; without
/// `inPlace` it's written through the temp file anyway, as a tag past the padding is.
private func writeAndRescanRuns(inPlace: Bool) throws -> (write: [Double], rescan: [Double]) {
    let directory = try emptyCacheDirectory("bench-tag-write")
    let music = directory.appendingPathComponent("music", isDirectory: true)
    try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
    let path = music.appendingPathComponent("track.flac", isDirectory: false).path
    try FileManager.default.copyItem(atPath: try fixtureFLAC().path, toPath: path)
    let scanner = LibraryScanner(
        databaseURL: libraryFileURL(in: directory))
    _ = try scanner.scan(WatchedFolder(path: music.path, kind: .local))
    var writer = TagWriter(
        journal: TagUndoJournal(
            dataDirectory: directory.appendingPathComponent("undo", isDirectory: true)))
    writer.faults.writesInPlace = inPlace
    var write: [Double] = []
    var rescan: [Double] = []
    let fileNumber = { try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] }
    for run in 0...editorRuns {
        let before = try fileNumber() as? Int
        let start = DispatchTime.now().uptimeNanoseconds
        let report = writer.write(TagEdit(values: [.title: "Bench \(run)"]), to: [path])
        guard report.changed == [path] else {
            throw BenchError.expected("the title written: \(report.failures)")
        }
        let written = DispatchTime.now().uptimeNanoseconds
        guard (try fileNumber() as? Int == before) == inPlace else {
            throw BenchError.expected(inPlace ? "the title written in place" : "a new file")
        }
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

/// The first readable FLAC of the full fixture library.
private func fixtureFLAC() throws -> URL {
    let root = try defaultFixturesDirectory()
    _ = try generateFixtures(count: fullLibraryFileCount, in: root)
    let flac = try loadManifest(in: root).files.first {
        $0.container == .flac && $0.malformation == nil
    }
    guard let flac else { throw BenchError.expected("a fixture FLAC") }
    return root.appendingPathComponent(flac.path)
}

/// Tracks in the album a batch edit saves, and how big each is: the owner's 24-bit hi-res FLACs.
private let batchFileCount = 20
private let batchFileBytes = 40 * 1024 * 1024
/// The NAS's link, as the owner measured it: a 40 MB FLAC in about 0.7 s over gigabit.
private let nasBytesPerSecond = 57.0 * 1024 * 1024

/// A title saved to every track of an album of hi-res FLACs at once, as Save does on a
/// selection: in place, as when the title fits the padding, and through the temp file, as when
/// it doesn't; on this Mac's disk and on the slow simulated NAS.
let tagBatchBenchmarks = [
    Benchmark(
        name: "tag write: \(batchFileCount) 40 MB FLACs' titles in one batch, in place",
        budget: Budget(appleSilicon: 30, oldMac: 60, unit: .seconds)
    ) {
        try batchWrite(inPlace: true, nas: false)
    },
    Benchmark(
        name:
            "tag write: \(batchFileCount) 40 MB FLACs' titles in one batch, in place, slow simulated NAS",
        budget: Budget(appleSilicon: 60, oldMac: 60, unit: .seconds)
    ) {
        try batchWrite(inPlace: true, nas: true)
    },
    Benchmark(
        name:
            "tag write: \(batchFileCount) 40 MB FLACs' titles in one batch, through the temp file",
        budget: Budget(appleSilicon: 30, oldMac: 60, unit: .seconds)
    ) {
        try batchWrite(inPlace: false, nas: false)
    },
    Benchmark(
        name:
            "tag write: \(batchFileCount) 40 MB FLACs' titles in one batch, through the temp file, slow simulated NAS",
        budget: Budget(appleSilicon: 120, oldMac: 120, unit: .seconds)
    ) {
        try batchWrite(inPlace: false, nas: true)
    },
]

/// One batch write of a title to `batchFileCount` copies of a fixture FLAC grown to
/// `batchFileBytes` with audio bytes, in seconds. On the NAS every file system call the writer
/// makes on a music file is priced as `SimulatedLink` says; the journal stays on this Mac.
private func batchWrite(inPlace: Bool, nas: Bool) throws -> Measured {
    let directory = try emptyCacheDirectory("bench-tag-batch")
    let album = directory.appendingPathComponent("batch", isDirectory: true)
    try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
    var grown = try Data(contentsOf: try fixtureFLAC())
    grown.append(Data(count: batchFileBytes - grown.count))
    let paths = try (1...batchFileCount).map { track in
        let path = album.appendingPathComponent(
            String(format: "%02d.flac", track), isDirectory: false
        ).path
        try grown.write(to: URL(fileURLWithPath: path, isDirectory: false))
        return path
    }
    var writer = TagWriter(
        journal: TagUndoJournal(
            dataDirectory: directory.appendingPathComponent("undo", isDirectory: true)))
    writer.faults.writesInPlace = inPlace
    let link = SimulatedLink(
        roundTripSeconds: slowNAS.operationSeconds, bytesPerSecond: nasBytesPerSecond)
    if nas { writer.faults.fileCall = { link.price($0) } }
    var report: TagWriteReport?
    let elapsed = seconds {
        report = writer.write(TagEdit(values: [.title: "Batch"]), to: paths)
    }
    guard let report, report.changed == paths else {
        throw BenchError.expected("every title written: \(report?.failures ?? [])")
    }
    try FileManager.default.removeItem(at: directory)
    let perFile = String(format: "%.2f s a file", elapsed / Double(paths.count))
    return Measured(
        value: elapsed,
        notes: [
            nas
                ? perFile
                    + String(
                        format: "; %d calls on the NAS, %.0f MB over its link", link.calls,
                        Double(link.bytes) / 1024 / 1024)
                : perFile
        ])
}

/// A NAS for the writer's file system calls: each is a round trip, and the bytes reads and
/// writes move share one link, so files written at once wait on each other's transfers but
/// not on each other's round trips. A clone is a copy, which SMB can't do on the server.
private final class SimulatedLink: @unchecked Sendable {
    private let roundTripSeconds: Double
    private let bytesPerSecond: Double
    // Guarded by `lock`.
    private let lock = NSLock()
    private var linkFreeAt = 0.0
    private var callCount = 0
    private var byteCount = 0

    init(roundTripSeconds: Double, bytesPerSecond: Double) {
        self.roundTripSeconds = roundTripSeconds
        self.bytesPerSecond = bytesPerSecond
    }

    var calls: Int { lock.withLock { callCount } }
    var bytes: Int { lock.withLock { byteCount } }

    func price(_ call: FileCall) {
        let moved =
            switch call {
            case .read(let bytes), .write(let bytes): bytes
            case .clone(let bytes): 2 * bytes
            default: 0
            }
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        let done = lock.withLock {
            callCount += 1
            byteCount += moved
            guard moved > 0 else { return now + roundTripSeconds }
            linkFreeAt = max(linkFreeAt, now) + Double(moved) / bytesPerSecond
            return max(now + roundTripSeconds, linkFreeAt)
        }
        Thread.sleep(forTimeInterval: done - now)
    }
}

private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

private func runsNote(_ values: [Double]) -> String {
    "runs: " + values.map { String(format: "%.1f ms", $0) }.joined(separator: ", ")
}
