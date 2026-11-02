import Darwin
import Fixtures
import Foundation
import Library
import SQLite
import Settings

/// The fixture library scanned into a fresh database once per run, which every library
/// benchmark then measures against.
struct ScannedLibrary: @unchecked Sendable {
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

let scannedLibrary = Result { () throws -> ScannedLibrary in
    let root = try defaultFixturesDirectory()
    _ = try generateFixtures(count: fullLibraryFileCount, in: root)
    let directory = root.deletingLastPathComponent().appendingPathComponent("bench-library")
    if FileManager.default.fileExists(atPath: directory.path) {
        try FileManager.default.removeItem(at: directory)
    }
    let databaseURL = libraryFileURL(in: directory)
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
        budget: Budget(appleSilicon: 5, oldMac: 180, unit: .seconds)
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
        budget: Budget(appleSilicon: 1.5, oldMac: 15, unit: .seconds)
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
        name: "library: scan \(fastNAS.fileCount) fixture files on a simulated NAS, tuned",
        budget: Budget(appleSilicon: 4, oldMac: 8, unit: .seconds)
    ) {
        let fixed = try simulatedNetworkScan(fastNAS, readers: fixedNetworkReaders)
        let tuned = try simulatedNetworkScan(fastNAS, readers: nil)
        let speedup = fixed.seconds / tuned.seconds
        // The point of tuning: a NAS that serves 16 at once is wasted on 4 readers.
        guard speedup >= 2 else {
            throw BenchError.expected(
                String(
                    format: "tuned readers to beat a fixed %d by 2x, not %.2fx",
                    fixedNetworkReaders, speedup))
        }
        guard case .tuned(let levels, _) = tuned.summary.readers else {
            throw BenchError.expected("tuned readers: \(String(describing: tuned.summary.readers))")
        }
        return Measured(
            value: tuned.seconds,
            notes: [
                String(
                    format: "%.0f ms per operation, %d at once; %.0f files/s tuned, %.0f files/s"
                        + " with %d readers (%.2f s), %.1fx faster",
                    fastNAS.operationSeconds * 1e3, fastNAS.capacity, rate(tuned), rate(fixed),
                    fixedNetworkReaders, fixed.seconds, speedup),
                "readers " + levels.map(String.init).joined(separator: "→"),
            ])
    },
    Benchmark(
        name:
            "library: scan \(slowNAS.fileCount) fixture files on a slow simulated NAS that"
            + " serves many at once, tuned",
        budget: Budget(appleSilicon: 10, oldMac: 20, unit: .seconds)
    ) {
        let tuned = try simulatedNetworkScan(slowNAS, readers: nil)
        let fixed = try slowNASFixedReaders.map { readers in
            (readers, try simulatedNetworkScan(slowNAS, readers: readers))
        }
        let (bestReaders, best) = fixed.min { $0.1.seconds < $1.1.seconds }!
        let share = best.seconds / tuned.seconds
        // A NAS that serves dozens of slow requests at once is wasted on a level that stays low.
        guard share >= tunedShareOfBestFixed else {
            throw BenchError.expected(
                String(
                    format: "tuned readers to reach %.0f%% of a fixed %d's throughput, not %.0f%%",
                    tunedShareOfBestFixed * 100, bestReaders, share * 100))
        }
        guard case .tuned(let levels, _) = tuned.summary.readers,
            levels.last! >= slowNASFixedReaders[0]
        else {
            throw BenchError.expected(
                "tuned readers to end at \(slowNASFixedReaders[0]) or more:"
                    + " \(String(describing: tuned.summary.readers))")
        }
        return Measured(
            value: tuned.seconds,
            notes: [
                String(
                    format: "%.0f ms per operation, %.0f ms per listing, %d at once; %.0f files/s"
                        + " tuned, %.0f%% of the best fixed level",
                    slowNAS.operationSeconds * 1e3, slowNAS.listingSeconds * 1e3,
                    slowNAS.capacity, rate(tuned), share * 100),
                fixed.map { String(format: "%d readers: %.0f files/s", $0.0, rate($0.1)) }
                    .joined(separator: ", "),
                "readers " + levels.map(String.init).joined(separator: "→"),
            ])
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
        budget: Budget(appleSilicon: 20, oldMac: 80, unit: .milliseconds)
    ) {
        let index = try scannedLibrary.get().index
        let typed = try typedQueries(index)
        let samples = try millisecondSamples(
            typed.map { text in
                {
                    // The window reads the totals beside the rows.
                    let filter = TrackFilter(search: text)
                    _ = try index.trackTotals(ids: try index.trackIDs(filter, sortedBy: .artist))
                }
            })
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
            for column in TrackColumn.allCases where column.isSortable {
                for ascending in [true, false] {
                    runs.append {
                        let ids = try index.trackIDs(sortedBy: column, ascending: ascending)
                        _ = try index.trackTotals(ids: ids)
                    }
                }
            }
        }
        let samples = try millisecondSamples(runs)
        return Measured(value: p95(samples), notes: [slowestNote(samples)])
    },
    Benchmark(
        name: "library: browser pane query (p95)",
        budget: Budget(appleSilicon: 2, oldMac: 60, unit: .milliseconds)
    ) {
        let index = try scannedLibrary.get().index
        let genres = try index.genres()
        let artists = try index.artists()
        var runs: [() throws -> Void] = [
            { _ = try index.genres() }, { _ = try index.artists() }, { _ = try index.albums() },
        ]
        runs += genres.map { genre in { _ = try index.artists(TrackFilter(genre: genre.id)) } }
        // The Artist pane grouped by album artist, as `library.groupByAlbumArtist` lists it.
        runs.append { _ = try index.artists(TrackFilter(groupByAlbumArtist: true)) }
        runs += genres.map { genre in
            { _ = try index.artists(TrackFilter(genre: genre.id, groupByAlbumArtist: true)) }
        }
        runs += artists.prefix(200).map { artist in
            { _ = try index.albums(TrackFilter(artist: artist.id)) }
        }
        runs += genres.map { genre in { _ = try index.albums(TrackFilter(genre: genre.id)) } }
        let samples = try millisecondSamples(runs)
        return Measured(
            value: p95(samples),
            notes: [
                "\(samples.count) queries over \(genres.count) genres and \(artists.count) artists"
            ])
    },
]

/// A NAS the network scan benchmarks simulate, and how many fixture files they scan on it.
private struct SimulatedProfile {
    var operationSeconds: Double
    var listingSeconds: Double
    var capacity: Int
    var fileDelay: SimulatedNAS.FileDelay?
    var fileCount: Int
}

/// Every operation takes 2 ms, and it serves 16 at once, so more readers than that only queue.
private let fastNAS = SimulatedProfile(
    operationSeconds: 0.002, listingSeconds: 0.002, capacity: 16, fileDelay: nil, fileCount: 3000)
/// The owner's NAS as measured over SMB, cold: a file costs about 60 ms, half of it in three
/// operations and half a disk delay with a long tail, and 16 in flight read about 16x as fast
/// as one; listing a directory costs about 45 ms. Fixture albums hold about ten files each,
/// under a folder per artist.
private let slowNAS = SimulatedProfile(
    operationSeconds: 0.010, listingSeconds: 0.045, capacity: 24,
    fileDelay: SimulatedNAS.FileDelay(medianSeconds: 0.013, sigma: 1.3), fileCount: 2000)
/// The fixed levels the slow NAS's tuned scan is held against, and the share of the best one's
/// throughput it must reach.
private let slowNASFixedReaders = [16, 32]
private let tunedShareOfBestFixed = 0.8
/// What the tuning is measured against: the fixed count network scans read before it.
private let fixedNetworkReaders = 4

private func rate(_ scan: (seconds: Double, summary: ScanSummary)) -> Double {
    Double(scan.summary.read) / scan.seconds
}

/// Scans the first artists' folders of the fixture library, about `profile.fileCount` files,
/// through a simulated NAS into a new index, and returns the seconds and the summary.
private func simulatedNetworkScan(_ profile: SimulatedProfile, readers: Int?) throws -> (
    seconds: Double, summary: ScanSummary
) {
    let root = try defaultFixturesDirectory()
    _ = try generateFixtures(count: fullLibraryFileCount, in: root)
    let byArtist = Dictionary(grouping: try loadManifest(in: root).files) {
        String($0.path.prefix { $0 != "/" })
    }
    var artists: [String] = []
    var files = 0
    for artist in byArtist.keys.sorted() where files < profile.fileCount {
        artists.append(root.path + "/" + artist)
        files += byArtist[artist]!.count
    }
    return try withScratchDirectory("simulated-nas") { directory in
        let scanner = LibraryScanner(
            databaseURL: libraryFileURL(in: directory),
            networkReaders: readers,
            access: SimulatedNAS(
                operationSeconds: profile.operationSeconds,
                listingSeconds: profile.listingSeconds, capacity: profile.capacity,
                fileDelay: profile.fileDelay))
        var scanned: ScanSummary?
        let elapsed = try seconds {
            scanned = try scanner.scan(
                WatchedFolder(path: root.path, kind: .network), only: artists)
        }
        guard let summary = scanned, summary.read == files, summary.issues.isEmpty else {
            throw BenchError.expected(
                "the scan to read all \(files) files: \(String(describing: scanned))")
        }
        return (elapsed, summary)
    }
}

/// Every prefix of a few artist, album and title words, as someone typing them would send.
func typedQueries(_ index: LibraryIndex) throws -> [String] {
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
func footprintMB() throws -> Double {
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
