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
        budget: Budget(appleSilicon: 4, oldMac: 12, unit: .milliseconds)
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
        let samples = try withLibraryCopy("keystrokes") {
            try secondKeystrokes($0, scanning: false)
        }
        return Measured(value: p95(samples), notes: [slowestNote(samples)])
    },
    Benchmark(
        name:
            "reader: second of two search keystrokes \(keystrokeGapMs) ms apart, during a scan"
            + " (p95)",
        budget: Budget(appleSilicon: 50, oldMac: 150, unit: .milliseconds)
    ) {
        let samples = try withLibraryCopy("keystrokes-scan") {
            try secondKeystrokes($0, scanning: true)
        }
        return Measured(value: p95(samples), notes: [slowestNote(samples)])
    },
]

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
/// totals are read. `scanning` rescans every file meanwhile, with the browser's refreshes.
private func secondKeystrokes(_ databaseURL: URL, scanning: Bool) throws -> [Double] {
    let folder = try scannedLibrary.get().folder
    let scan = scanning ? RepeatedScan(databaseURL, folder) : nil
    let samples = Result { try typeKeystrokes(databaseURL, scanning: scanning) }
    try scan?.stop()
    return try samples.get()
}

private func typeKeystrokes(_ databaseURL: URL, scanning: Bool) throws -> [Double] {
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
            while scanning, !Task.isCancelled {
                try await Task.sleep(nanoseconds: UInt64(scanRefreshSeconds * 1e9))
                // What `LibraryBrowser.refreshNow` reads.
                await model.refresh()
                _ = try await reader.trackTotals(ids: model.trackIDs)
                _ = try await reader.dismissedProblems()
                _ = try await reader.fileIssues()
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

/// Rescans every file of `folder` into the database at `databaseURL` on a thread of its own,
/// again and again until stopped, as a scan of a changed library writes it.
private final class RepeatedScan: @unchecked Sendable {
    // `running` and `failure` are guarded by `lock`.
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
