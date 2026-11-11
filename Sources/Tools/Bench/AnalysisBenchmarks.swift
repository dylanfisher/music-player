import Analysis
import Fixtures
import Foundation
import Library
import Settings

/// The file the analysis rows time: five minutes of full-band 24/96 noise, which FLAC can't
/// shrink much, so it reads as much as any 24/96 recording of that length.
private let benchSeconds = 300

/// One analysis of the bench file locally, with the footprint it added at its peak.
private struct LocalAnalysis {
    var seconds: Double
    var footprintBeforeMB: Double
    var footprintPeakMB: Double
    var fileMB: Double
}

private let benchFile = Result {
    try analysisFixture(.hiRes, seconds: benchSeconds, in: try defaultPlaybackFixturesDirectory())
}

private let localAnalysis = Result { () throws -> LocalAnalysis in
    let url = try benchFile.get()
    // A first run, so the file is in the page cache, as a second look at a local file is.
    _ = try analyzeFile(at: url)
    let before = try footprintMB()
    let peak = PeakFootprint()
    let elapsed = try seconds { _ = try analyzeFile(at: url) }
    let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
    return LocalAnalysis(
        seconds: elapsed, footprintBeforeMB: before, footprintPeakMB: try peak.stop(),
        fileMB: Double(size) / 1e6)
}

/// The fixture files Analyze Library's row reads: the first of the library that analysis
/// takes, neither DSD nor broken.
private let passFileCount = 200

/// A folder of the first `passFileCount` such files, scanned into a library of its own in
/// `directory`; the library's database.
private func passLibrary(in directory: URL) throws -> URL {
    let root = try defaultFixturesDirectory()
    _ = try generateFixtures(count: fullLibraryFileCount, in: root)
    let files = try loadManifest(in: root).files.filter {
        $0.malformation == nil && $0.container != .dsf && $0.container != .dff
    }.prefix(passFileCount)
    let music = directory.appendingPathComponent("files")
    for file in files {
        let copy = music.appendingPathComponent(file.path)
        try FileManager.default.createDirectory(
            at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent(file.path), to: copy)
    }
    let databaseURL = libraryFileURL(in: directory)
    let summary = try LibraryScanner(databaseURL: databaseURL).scan(
        WatchedFolder(path: music.path, kind: .local))
    guard summary.read == passFileCount, summary.failed == 0 else {
        throw BenchError.expected("\(passFileCount) fixture files scanned: \(summary)")
    }
    return databaseURL
}

/// Waits on this thread for `body`, which runs on a task of its own: for the soak's threads
/// and the benchmarks, which aren't async.
func waited<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let done = DispatchSemaphore(value: 0)
    // Written by the task before `done.signal()` and read after `done.wait()`: the semaphore
    // orders the handoff.
    nonisolated(unsafe) var result: Result<T, any Error>?
    Task.detached {
        do {
            result = .success(try await body())
        } catch {
            result = .failure(error)
        }
        done.signal()
    }
    done.wait()
    return try result!.get()
}

let analysisBenchmarks = [
    Benchmark(
        name: "analysis: a 5-minute 24/96 FLAC, local",
        budget: Budget(appleSilicon: 2, oldMac: 12, unit: .seconds)
    ) {
        let analysis = try localAnalysis.get()
        return Measured(
            value: analysis.seconds,
            notes: [
                String(
                    format: "%.0f MB, %.0fx real time, from the page cache", analysis.fileMB,
                    Double(benchSeconds) / analysis.seconds)
            ])
    },
    Benchmark(
        name: "analysis: the same on the slow simulated NAS",
        budget: Budget(appleSilicon: 6, oldMac: 20, unit: .seconds)
    ) {
        let url = try benchFile.get()
        let elapsed = try seconds { _ = try analyzeFile(at: url, latency: nasFileLatency) }
        return Measured(
            value: elapsed,
            notes: [
                String(
                    format: "%.0f ms to open, %.0f ms a 1 MB block, as the play rows wait",
                    nasFileLatency.openSeconds * 1000, nasFileLatency.readSeconds * 1000)
            ])
    },
    Benchmark(
        name: "analysis: Analyze Library, \(passFileCount) fixture files on the slow simulated NAS",
        budget: Budget(appleSilicon: 15, oldMac: 40, unit: .seconds)
    ) {
        try withScratchDirectory("library-pass") { directory in
            let cache = MeasuresCache(databaseURL: try passLibrary(in: directory))
            let pass = LibraryAnalysis(
                cache: cache, latency: nasFileLatency, scanRunning: { false }, report: { _ in })
            var ended: LibraryAnalysis.Progress?
            let elapsed = try seconds { ended = try waited { await pass.start().value } }
            guard let ended, ended.stage == .finished, ended.analyzed == passFileCount else {
                throw BenchError.expected("every file analyzed: \(String(describing: ended))")
            }
            return Measured(
                value: elapsed,
                notes: [
                    String(
                        format: "%d failed; %.0f ms a file, %d files at once at utility priority",
                        ended.failed, elapsed * 1000 / Double(passFileCount),
                        LibraryAnalysis.filesAtOnce)
                ])
        }
    },
    // Measured as growth, since earlier benchmarks in the same process leave their own memory.
    Benchmark(
        name: "analysis: memory it adds at its peak",
        budget: Budget(appleSilicon: 10, oldMac: 10, unit: .megabytes)
    ) {
        let analysis = try localAnalysis.get()
        return Measured(
            value: analysis.footprintPeakMB - analysis.footprintBeforeMB,
            notes: [
                String(
                    format: "footprint %.0f MB before, %.0f MB at the peak",
                    analysis.footprintBeforeMB, analysis.footprintPeakMB)
            ])
    },
]
