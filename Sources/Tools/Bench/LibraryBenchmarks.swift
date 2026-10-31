import Darwin
import Fixtures
import Foundation
import Library
import SQLite
import Settings

/// The fixture library scanned into a fresh database once per run, which every library
/// benchmark then measures against.
private struct ScannedLibrary: @unchecked Sendable {
    var folder: WatchedFolder
    var databaseURL: URL
    var scanSeconds: Double
    var summary: ScanSummary
    var footprintBeforeMB: Double
    var footprintPeakMB: Double
    var footprintAfterMB: Double
    var databaseMB: Double
    var index: LibraryIndex
}

private let scannedLibrary = Result { () throws -> ScannedLibrary in
    let root = try defaultFixturesDirectory()
    _ = try generateFixtures(count: fullLibraryFileCount, in: root)
    let directory = root.deletingLastPathComponent().appendingPathComponent("bench-library")
    if FileManager.default.fileExists(atPath: directory.path) {
        try FileManager.default.removeItem(at: directory)
    }
    let databaseURL = directory.appendingPathComponent("library.sqlite")
    let folder = WatchedFolder(path: root.path, kind: .local)
    let before = try footprintMB()
    let peak = PeakFootprint()
    var scanned: ScanSummary?
    let elapsed = try seconds {
        scanned = try LibraryScanner(databaseURL: databaseURL).scan(folder)
    }
    let peakMB = try peak.stop()
    guard let summary = scanned, summary.read == fullLibraryFileCount, summary.issues.isEmpty
    else {
        throw BenchError.expected(
            "the scan to read every fixture file cleanly: \(String(describing: scanned))")
    }
    let index = try LibraryIndex(at: databaseURL)
    return ScannedLibrary(
        folder: folder, databaseURL: databaseURL, scanSeconds: elapsed, summary: summary,
        footprintBeforeMB: before, footprintPeakMB: peakMB, footprintAfterMB: try footprintMB(),
        databaseMB: Double(try Database.sizeBytes(at: databaseURL)) / 1e6, index: index)
}

let libraryBenchmarks = [
    Benchmark(
        name: "library: scan \(fullLibraryFileCount) fixture files into a new index",
        budget: Budget(appleSilicon: 60, oldMac: 180, unit: .seconds)
    ) {
        let library = try scannedLibrary.get()
        return Measured(
            value: library.scanSeconds,
            notes: [
                String(
                    format: "%.0f files/s, %d failed as the fixtures intend",
                    Double(library.summary.read) / library.scanSeconds, library.summary.failed)
            ])
    },
    Benchmark(
        name: "library: rescan the fixture library with no changes",
        budget: Budget(appleSilicon: 5, oldMac: 15, unit: .seconds)
    ) {
        let library = try scannedLibrary.get()
        var rescanned: ScanSummary?
        let elapsed = try seconds {
            rescanned = try LibraryScanner(databaseURL: library.databaseURL).scan(library.folder)
        }
        guard let summary = rescanned, summary.read == 0, summary.removed == 0 else {
            throw BenchError.expected(
                "a rescan to read and remove nothing: \(String(describing: rescanned))")
        }
        return Measured(
            value: elapsed,
            notes: [String(format: "%.0f files/s", Double(summary.unchanged) / elapsed)])
    },
    Benchmark(
        name: "library: index database size",
        budget: Budget(appleSilicon: 60, oldMac: 60, unit: .megabytes)
    ) {
        Measured(value: try scannedLibrary.get().databaseMB)
    },
    // Measured as growth, since earlier benchmarks in the same process leave their own memory.
    Benchmark(
        name: "library: memory a scan adds at its peak",
        budget: Budget(appleSilicon: 50, oldMac: 50, unit: .megabytes)
    ) {
        let library = try scannedLibrary.get()
        return Measured(
            value: library.footprintPeakMB - library.footprintBeforeMB,
            notes: [
                String(
                    format: "footprint %.0f MB before, %.0f MB at the peak, %.0f MB after",
                    library.footprintBeforeMB, library.footprintPeakMB, library.footprintAfterMB)
            ])
    },
    Benchmark(
        name: "library: search keystroke, sorted by artist (p95)",
        budget: Budget(appleSilicon: 30, oldMac: 80, unit: .milliseconds)
    ) {
        let index = try scannedLibrary.get().index
        let typed = try typedQueries(index)
        let samples = try millisecondSamples(
            typed.map { text in { _ = try index.trackIDs(sortedBy: .artist, matching: text) } })
        return Measured(
            value: p95(samples),
            notes: [
                "\(samples.count) keystrokes, median \(format(samples.sorted()[samples.count / 2])) ms"
            ])
    },
    Benchmark(
        name: "library: sort every track by each column (p95)",
        budget: Budget(appleSilicon: 100, oldMac: 250, unit: .milliseconds)
    ) {
        let index = try scannedLibrary.get().index
        var runs: [() throws -> Void] = []
        for _ in 0..<3 {
            for column in TrackSortColumn.allCases {
                for ascending in [true, false] {
                    runs.append { _ = try index.trackIDs(sortedBy: column, ascending: ascending) }
                }
            }
        }
        let samples = try millisecondSamples(runs)
        return Measured(value: p95(samples), notes: ["slowest \(format(samples.max()!)) ms"])
    },
    Benchmark(
        name: "library: browser pane query (p95)",
        budget: Budget(appleSilicon: 20, oldMac: 60, unit: .milliseconds)
    ) {
        let index = try scannedLibrary.get().index
        let genres = try index.genres()
        let artists = try index.artists()
        var runs: [() throws -> Void] = [
            { _ = try index.genres() }, { _ = try index.artists() }, { _ = try index.albums() },
        ]
        runs += genres.map { genre in { _ = try index.artists(genre: genre.id) } }
        runs += artists.prefix(200).map { artist in { _ = try index.albums(artist: artist.id) } }
        runs += genres.map { genre in { _ = try index.albums(genre: genre.id) } }
        let samples = try millisecondSamples(runs)
        return Measured(
            value: p95(samples),
            notes: [
                "\(samples.count) queries over \(genres.count) genres and \(artists.count) artists"
            ])
    },
]

/// Every prefix of a few artist, album and title words, as someone typing them would send.
private func typedQueries(_ index: LibraryIndex) throws -> [String] {
    let names = try index.artists().prefix(10).map(\.name) + index.albums().prefix(10).map(\.name)
    return names.flatMap { name in
        name.indices.map { String(name[...$0]) }
    }
}

private func format(_ milliseconds: Double) -> String { String(format: "%.2f", milliseconds) }

/// Samples the footprint every 10 ms on its own thread until stopped.
private final class PeakFootprint: @unchecked Sendable {
    // Every field but `done` is guarded by `lock`.
    private let lock = NSLock()
    private var peakMB = 0.0
    private var running = true
    private var failure: (any Error)?
    private let done = DispatchSemaphore(value: 0)

    init() {
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                do {
                    let current = try footprintMB()
                    lock.withLock { peakMB = max(peakMB, current) }
                } catch {
                    lock.withLock {
                        failure = error
                        running = false
                    }
                }
                usleep(10_000)
            }
            done.signal()
        }
    }

    func stop() throws -> Double {
        lock.withLock { running = false }
        done.wait()
        return try lock.withLock {
            if let failure { throw failure }
            return peakMB
        }
    }
}

/// This process's physical footprint, as Activity Monitor's Memory column shows it.
private func footprintMB() throws -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { throw BenchError.expected("task_info to succeed") }
    return Double(info.phys_footprint) / 1e6
}
