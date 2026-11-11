import Analysis
import Foundation
import Library
import LibraryBrowser
import SQLite
import Settings

/// How long after one search keystroke the next is typed, in milliseconds, as a fast typist
/// sends them.
private let keystrokeGapMs = 50
/// How many keystroke pairs each keystroke benchmark times.
private let keystrokePairs = 40
/// How often the browser refreshes while a scan runs, as `LibraryBrowser` does.
private let scanRefreshSeconds = 2.0

let readerBenchmarks = [
    Benchmark(
        name: "reader: totals of every track right after a play is recorded (p95)",
        budget: Budget(appleSilicon: 2, oldMac: 12, unit: .milliseconds)
    ) {
        try withLibraryCopy("totals-after-play") { databaseURL in
            let index = try LibraryIndex(at: databaseURL)
            let ids = try index.trackIDs(sortedBy: .artist)
            let paths = Array(try index.paths(ids: Array(ids.prefix(30))).values)
            _ = try index.trackTotals(ids: ids)
            let warm = try medianMilliseconds(iterations: 10) {
                _ = try index.trackTotals(ids: ids)
            }
            let now = Date().timeIntervalSince1970
            var samples: [Double] = []
            for (offset, path) in paths.enumerated() {
                // The window adds up its list again after each play it records.
                try index.recordPlay(path, at: now + Double(offset))
                samples += try millisecondSamples([{ _ = try index.trackTotals(ids: ids) }])
            }
            return Measured(
                value: p95(samples),
                notes: [
                    "\(ids.count) tracks, \(samples.count) plays; "
                        + String(format: "%.2f ms with no write between", warm)
                ])
        }
    },
    Benchmark(
        name: "reader: second of two search keystrokes \(keystrokeGapMs) ms apart, idle (p95)",
        budget: Budget(appleSilicon: 20, oldMac: 80, unit: .milliseconds)
    ) {
        let samples = try withLibraryCopy("keystrokes") { try secondKeystrokes($0, .idle) }
        return Measured(value: p95(samples), notes: [slowestNote(samples)])
    },
    Benchmark(
        name:
            "reader: second of two search keystrokes \(keystrokeGapMs) ms apart, during a scan"
            + " (p95)",
        budget: Budget(appleSilicon: 50, oldMac: 150, unit: .milliseconds)
    ) {
        let samples = try withLibraryCopy("keystrokes-scan") { try secondKeystrokes($0, .scan) }
        return Measured(value: p95(samples), notes: [slowestNote(samples)])
    },
    // Analyze Library writes a row a file, and the browser refreshes every 2 s while it runs,
    // so search keeps the idle budget.
    Benchmark(
        name:
            "reader: second of two search keystrokes \(keystrokeGapMs) ms apart, during Analyze"
            + " Library (p95)",
        budget: Budget(appleSilicon: 20, oldMac: 80, unit: .milliseconds)
    ) {
        let samples = try withLibraryCopy("keystrokes-analysis") {
            try secondKeystrokes($0, .analysis)
        }
        return Measured(value: p95(samples), notes: [slowestNote(samples)])
    },
]

/// What runs beside the keystrokes.
private enum KeystrokeLoad {
    case idle
    /// Every file rescanned, again and again.
    case scan
    /// Analyze Library over every file, again and again.
    case analysis
}

/// Runs `body` with a copy of the scanned fixture library's database, so what it writes doesn't
/// reach the other benchmarks.
func withLibraryCopy<T>(_ name: String, _ body: (URL) throws -> T) throws -> T {
    let source = try scannedLibrary.get().databaseURL
    return try withScratchDirectory(name) { directory in
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = libraryFileURL(in: directory)
        for suffix in ["", Database.walSuffix]
        where FileManager.default.fileExists(atPath: source.path + suffix) {
            try FileManager.default.copyItem(
                atPath: source.path + suffix, toPath: databaseURL.path + suffix)
        }
        return try body(databaseURL)
    }
}

/// Types pairs of search keystrokes into a browser over the library at `databaseURL`, as the
/// search field sends them, and times the second of each from when it's typed until its rows and
/// totals are read, with `load` running meanwhile and the browser refreshing as it does then.
private func secondKeystrokes(_ databaseURL: URL, _ load: KeystrokeLoad) throws -> [Double] {
    let folder = try scannedLibrary.get().folder
    let scan = load == .scan ? RepeatedScan(databaseURL, folder) : nil
    let analysis = load == .analysis ? try RepeatedAnalysis(databaseURL) : nil
    let samples = Result { try typeKeystrokes(databaseURL, refreshing: load != .idle) }
    try scan?.stop()
    let analyzed = try analysis?.stop()
    if analyzed == 0 { throw BenchError.expected("files analyzed beside the keystrokes") }
    return try samples.get()
}

private func typeKeystrokes(_ databaseURL: URL, refreshing: Bool) throws -> [Double] {
    try onMainActor {
        let reader = try LibraryReader(databaseURL: databaseURL)
        let model = BrowserModel(
            reader: reader, sortColumn: .artist, ascending: true, groupByAlbumArtist: true)
        await model.load(BrowserState(source: nil))
        // The window adds up the list as it first shows it.
        _ = try await reader.trackTotals(ids: model.trackIDs)
        let typed = try typedQueries(try LibraryIndex(at: databaseURL))
        let pairs = (0..<keystrokePairs).map { pair in
            let index = (pair * 7) % (typed.count - 1)
            return (typed[index], typed[index + 1])
        }
        let refreshing = Task { @MainActor in
            while refreshing, !Task.isCancelled {
                try await Task.sleep(nanoseconds: UInt64(scanRefreshSeconds * 1e9))
                // What `LibraryBrowser.refreshNow` reads, on the connection it reads them on.
                await model.refresh()
                _ = try await reader.refreshes.trackTotals(ids: model.trackIDs)
                _ = try await reader.refreshes.dismissedProblems()
                _ = try await reader.refreshes.fileIssues()
            }
        }
        func keystroke(_ text: String) async throws {
            await model.setSearch(text)
            _ = try await reader.trackTotals(ids: model.trackIDs)
        }
        func typePairs() async throws -> [Double] {
            var samples: [Double] = []
            for (first, second) in pairs {
                let typing = Task { @MainActor in try await keystroke(first) }
                try await Task.sleep(nanoseconds: UInt64(keystrokeGapMs) * 1_000_000)
                let start = DispatchTime.now().uptimeNanoseconds
                try await keystroke(second)
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                try await typing.value
                try await keystroke("")
            }
            return samples
        }
        let samples: Result<[Double], any Error>
        do {
            samples = .success(try await typePairs())
        } catch {
            samples = .failure(error)
        }
        refreshing.cancel()
        do {
            try await refreshing.value
        } catch is CancellationError {}
        return try samples.get()
    }
}

/// Analyze Library over the library at `databaseURL`, its measures cleared at each end to go
/// again, until stopped.
final class RepeatedAnalysis: Sendable {
    private let pass: LibraryAnalysis
    private let runs: Task<Int, any Error>
    private let stopping = Stopping()

    // `stopped` is guarded by `lock`.
    private final class Stopping: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        var isStopped: Bool {
            get { lock.withLock { stopped } }
            set { lock.withLock { stopped = newValue } }
        }
    }

    init(_ databaseURL: URL) throws {
        let pass = LibraryAnalysis(
            cache: MeasuresCache(databaseURL: databaseURL), scanRunning: { false },
            report: { _ in })
        self.pass = pass
        let stopping = stopping
        runs = Task.detached {
            var analyzed = 0
            while !stopping.isStopped {
                let ended = await pass.start().value
                analyzed += ended.analyzed - ended.failed
                guard ended.stage == .finished else { break }
                try Database(at: databaseURL).execute("DELETE FROM measures")
            }
            return analyzed
        }
    }

    /// Pauses the run going and returns how many files were analyzed in all.
    func stop() throws -> Int {
        stopping.isStopped = true
        let pass = pass
        let runs = runs
        return try waited {
            // Again and again, as a run may start just after a pause.
            let pausing = Task.detached {
                while true {
                    await pass.pause()
                    do {
                        try await Task.sleep(nanoseconds: 100_000_000)
                    } catch {
                        return
                    }
                }
            }
            let analyzed = try await runs.value
            pausing.cancel()
            return analyzed
        }
    }
}

/// Rescans every file of `folder` into the database at `databaseURL` on a thread of its own,
/// again and again until stopped, as a scan of a changed library writes it.
/// `running` and `failure` are guarded by `lock`.
private final class RepeatedScan: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var failure: (any Error)?
    private let done = DispatchSemaphore(value: 0)

    init(_ databaseURL: URL, _ folder: WatchedFolder) {
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                do {
                    let database = try Database(at: databaseURL)
                    // A stored time no file has makes the scan read and store every file again.
                    try database.execute("UPDATE files SET modified_seconds = 0")
                    _ = try LibraryScanner(databaseURL: databaseURL).scan(folder)
                } catch {
                    lock.withLock {
                        failure = error
                        running = false
                    }
                }
            }
            done.signal()
        }
    }

    /// Waits for the scan under way to end, and throws what any scan failed with.
    func stop() throws {
        lock.withLock { running = false }
        done.wait()
        if let failure = lock.withLock({ failure }) { throw failure }
    }
}
