import Foundation
import Library
import LibraryBrowser
import Settings

let windowBenchmarks = [
    Benchmark(
        name: "window: launch to the first rows drawn, fixture library indexed (median of 3)",
        budget: Budget(appleSilicon: 1, oldMac: 2.5, unit: .seconds)
    ) {
        let runs = try windowRuns.get()
        let launches = runs.map(\.launchSeconds)
        return Measured(
            value: launches.sorted()[launches.count / 2],
            notes: [
                "each run: " + launches.map { String(format: "%.3f s", $0) }.joined(separator: ", ")
                    + "; \(runs[0].rows) rows"
            ])
    },
    Benchmark(
        name: "window: memory after scrolling every row, with each album's art",
        budget: Budget(appleSilicon: 120, oldMac: 250, unit: .megabytes)
    ) {
        let runs = try windowRuns.get()
        let worst = runs.max { $0.scrolledMB < $1.scrolledMB }!
        return Measured(
            value: worst.scrolledMB,
            notes: [
                String(
                    format: "%.0f MB once the first rows drew; %d album covers decoded, %d failed",
                    worst.loadedMB, worst.artImages, worst.artFailures)
            ])
    },
    Benchmark(
        name: "window: CPU when idle, library open and not playing",
        budget: Budget(appleSilicon: 0.1, oldMac: 0.1, unit: .percentOfCore)
    ) {
        let idle = try idleUsage.get()
        return Measured(
            value: idle.cpuPercent,
            notes: [
                String(
                    format: "%.0f s after a %.0f s settle; %.2f interrupt wakeups a second",
                    idleSampleSeconds, idleSettleSeconds, idle.interruptWakeupsPerSecond)
            ])
    },
    Benchmark(
        name: "window: idle wakeups, library open and not playing",
        budget: Budget(appleSilicon: 1, oldMac: 1, unit: .wakeupsPerSecond)
    ) {
        Measured(value: try idleUsage.get().idleWakeupsPerSecond)
    },
    Benchmark(
        name: "window: search keystroke through the browser model (p95)",
        budget: Budget(appleSilicon: 20, oldMac: 80, unit: .milliseconds)
    ) {
        let library = try scannedLibrary.get()
        let typed = try typedQueries(library.index)
        let samples = try onMainActor {
            let model = try await loadedModel(library.databaseURL)
            var samples: [Double] = []
            for text in typed {
                let start = DispatchTime.now().uptimeNanoseconds
                await model.setSearch(text)
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            return samples
        }
        return Measured(value: p95(samples), notes: ["\(samples.count) keystrokes"])
    },
    Benchmark(
        name: "window: re-sort through the browser model (p95)",
        budget: Budget(appleSilicon: 100, oldMac: 250, unit: .milliseconds)
    ) {
        let library = try scannedLibrary.get()
        let samples = try onMainActor {
            let model = try await loadedModel(library.databaseURL)
            var samples: [Double] = []
            for column in TrackColumn.allCases where column.isSortable {
                for ascending in [true, false] {
                    let start = DispatchTime.now().uptimeNanoseconds
                    await model.setSort(column, ascending: ascending)
                    samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                }
            }
            return samples
        }
        return Measured(
            value: p95(samples), notes: [slowestNote(samples)])
    },
]

@MainActor
private func loadedModel(_ databaseURL: URL) async throws -> BrowserModel {
    let model = BrowserModel(
        reader: try LibraryReader(databaseURL: databaseURL), sortColumn: .artist, ascending: true,
        groupByAlbumArtist: true)
    await model.load(BrowserState(source: nil, genre: nil, artist: nil, album: nil))
    return model
}

/// How many times the app is launched; the launch benchmark takes the median.
private let windowRunCount = 3
/// The longest one run may take, scrolling included, before it counts as hung.
private let windowRunTimeoutSeconds = 300.0

/// The app launched `windowRunCount` times against the fixture library, already indexed, each
/// run in a fresh home folder holding a copy of the index.
private let windowRuns = Result { () throws -> [WindowReport] in
    let app = try appExecutable()
    return try (0..<windowRunCount).map { _ in
        try withIndexedHome { home in try measureWindow(app, home: home) }
    }
}

/// Runs `body` with a fresh home folder whose settings watch the fixture library and which holds
/// a copy of its index, then deletes the folder.
private func withIndexedHome<T>(_ body: (URL) throws -> T) throws -> T {
    let library = try scannedLibrary.get()
    return try withScratchDirectory("window") { directory in
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let paths = AppPaths(home: directory)
        try MainActor.assumeIsolated {
            // No shortcuts are set, so none is checked.
            let settings = ConfigStore(
                AppSettings(), fileURL: paths.configFile, check: { _, _, _ in nil },
                creating: true)
            try settings.set(\.watchedFolders, to: [library.folder])
        }
        try FileManager.default.copyItem(
            at: library.databaseURL, to: libraryFileURL(in: paths.dataDirectory))
        return try body(directory)
    }
}

/// How long the idle benchmark lets the app settle after launch, through the launch rescan, the
/// first rows and their art.
private let idleSettleSeconds = 20.0
/// How long it then samples the app. The 10-minute run in phase 14e measured the same rates.
private let idleSampleSeconds = 60.0

/// What the app used while idle: its window open on the fixture library, nothing playing.
private struct IdleUsage {
    var cpuPercent: Double
    var idleWakeupsPerSecond: Double
    var interruptWakeupsPerSecond: Double
}

/// The app launched on an indexed fixture library and left alone, sampled after it settles.
private let idleUsage = Result { () throws -> IdleUsage in
    let app = try appExecutable()
    return try withIndexedHome { home in
        let process = Process()
        process.executableURL = app
        process.arguments = ["--home", home.path]
        process.standardOutput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        defer {
            process.terminate()
            finished.wait()
        }
        Thread.sleep(forTimeInterval: idleSettleSeconds)
        let start = try usage(of: process.processIdentifier)
        Thread.sleep(forTimeInterval: idleSampleSeconds)
        let end = try usage(of: process.processIdentifier)
        guard process.isRunning else {
            throw BenchError.expected(
                "the app to keep running, not exit \(process.terminationStatus)")
        }
        return IdleUsage(
            cpuPercent: (end.cpuSeconds - start.cpuSeconds) / idleSampleSeconds * 100,
            idleWakeupsPerSecond: Double(end.idleWakeups - start.idleWakeups) / idleSampleSeconds,
            interruptWakeupsPerSecond: Double(end.interruptWakeups - start.interruptWakeups)
                / idleSampleSeconds)
    }
}

/// A process's CPU time so far and its wakeups: from idle, as `top` counts them in IDLEW, and
/// from interrupts, as Activity Monitor does.
private func usage(of pid: pid_t) throws -> (
    cpuSeconds: Double, idleWakeups: UInt64, interruptWakeups: UInt64
) {
    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
        }
    }
    guard status == 0 else { throw BenchError.expected("proc_pid_rusage to succeed, not \(errno)") }
    // In mach time units, which are nanoseconds only on Intel.
    var timebase = mach_timebase_info()
    mach_timebase_info(&timebase)
    let ticks = Double(info.ri_user_time + info.ri_system_time)
    return (
        ticks * Double(timebase.numer) / Double(timebase.denom) / 1e9, info.ri_pkg_idle_wkups,
        info.ri_interrupt_wkups
    )
}

/// Runs the app with `--measure-window` and reads the JSON line it prints.
private func measureWindow(_ app: URL, home: URL) throws -> WindowReport {
    let process = Process()
    process.executableURL = app
    process.arguments = ["--home", home.path, "--measure-window"]
    let output = Pipe()
    process.standardOutput = output
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    if finished.wait(timeout: .now() + windowRunTimeoutSeconds) == .timedOut {
        process.terminate()
        throw BenchError.expected("the app to finish measuring within \(windowRunTimeoutSeconds) s")
    }
    guard process.terminationStatus == 0,
        let line = String(decoding: data, as: UTF8.self).split(separator: "\n").last
    else {
        throw BenchError.expected(
            "the app to exit cleanly with a measurement, not status \(process.terminationStatus)")
    }
    return try WindowReport.decode(Data(line.utf8))
}

/// The app beside this Bench: the executable `scripts/bench` builds next to it, else the one in
/// `MusicPlayer.app`, for a copy of the release bundle. The bare one comes first, since a bundle
/// beside it can be left from an older build.
private func appExecutable() throws -> URL {
    let directory = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent()
    let candidates = [
        directory.appendingPathComponent("MusicPlayer"),
        directory.appendingPathComponent("MusicPlayer.app/Contents/MacOS/MusicPlayer"),
    ]
    guard
        let found = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        })
    else {
        throw BenchError.expected(
            "the MusicPlayer app beside Bench, at one of "
                + candidates.map(\.path).joined(separator: ", "))
    }
    return found
}

/// Runs `body` on the main actor and waits for it, turning the main run loop meanwhile so the
/// actor's work gets the main thread. Bench runs its benchmarks on the main thread.
private func onMainActor<T: Sendable>(_ body: @escaping @MainActor () async throws -> T) throws -> T
{
    try MainActor.assumeIsolated {
        let box = ResultBox<T>()
        Task { @MainActor in
            do {
                box.result = .success(try await body())
            } catch {
                box.result = .failure(error)
            }
        }
        while box.result == nil {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        return try box.result!.get()
    }
}

@MainActor
private final class ResultBox<T> {
    var result: Result<T, any Error>?
}
