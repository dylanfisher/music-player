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
        budget: Budget(appleSilicon: 250, oldMac: 250, unit: .megabytes)
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
        name: "window: search keystroke through the browser model (p95)",
        budget: Budget(appleSilicon: 30, oldMac: 80, unit: .milliseconds)
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
            for column in TrackColumn.allCases {
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
        reader: try LibraryReader(databaseURL: databaseURL), sortColumn: .artist, ascending: true)
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
    let library = try scannedLibrary.get()
    let app = try appExecutable()
    return try (0..<windowRunCount).map { _ in
        try withScratchDirectory("window") { directory in
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
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
            return try measureWindow(app, home: directory)
        }
    }
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
