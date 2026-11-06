import DisplayText
import Foundation
import HALOutput
import Library
import Log
import Metadata

private let logger = moduleLogger()

/// Analyze Library (ADR 0116): the measures of every track's file the index has none for, or
/// whose file changed since, one file at a time at background priority. It runs only when
/// started, waits while a scan runs, and stops when paused; a run started later lists what's
/// left from the index, so it carries on from there after a relaunch too. Each file is read
/// once, and its measures stored with the index's stamp, so nothing but the read touches the
/// share. No spectrogram is kept: the cache holds a few hundred, not a library.
public actor LibraryAnalysis {
    /// How long the pass waits before asking again whether a scan still runs.
    static let scanWaitSeconds = 1.0

    /// Where a run is.
    public struct Progress: Equatable, Sendable {
        public enum Stage: Equatable, Sendable {
            case analyzing
            case waitingForScan
            case paused
            case finished
        }

        public var stage: Stage
        /// Files this run has done, those that failed included, of `total`.
        public var analyzed = 0
        public var total = 0
        public var failed = 0
        /// Why the run couldn't list its files; it ends at once.
        public var problem: String?

        /// How far the run is, from 0 to 1.
        public var fraction: Double { total > 0 ? Double(analyzed) / Double(total) : 1 }

        /// "Analyzing library: 40 of 1,200", for the status bar.
        public var text: String {
            let count = "\(number(analyzed)) of \(number(total))"
            switch stage {
            case .analyzing: return "Analyzing library: \(count)"
            case .waitingForScan: return "Analyzing library: \(count), waiting for the scan"
            case .paused: return "Library analysis paused: \(count)"
            case .finished:
                if let problem { return "Couldn't list the files to analyze: \(problem)" }
                let files = "Library analyzed: \(number(analyzed)) files"
                return failed == 0
                    ? files : "\(files), \(number(failed)) couldn't be read; the log says why"
            }
        }
    }

    private let cache: MeasuresCache
    private let analyze: @Sendable (String) async throws -> FileMeasures
    private let scanRunning: @Sendable () async -> Bool
    private let report: @Sendable (Progress) -> Void
    /// The run going, by the number it was started as.
    private var run: (number: Int, task: Task<Progress, Never>)?
    private var runsStarted = 0

    /// `scanRunning` says whether a scan is under way; `report` hears each step of a run, off
    /// the main thread. `latency` makes every read wait as on a network volume, for benchmarks.
    public init(
        cache: MeasuresCache, latency: FileLatency? = nil,
        scanRunning: @escaping @Sendable () async -> Bool,
        report: @escaping @Sendable (Progress) -> Void
    ) {
        self.init(
            cache: cache,
            analyze: { path in
                try await offMain(priority: .background) {
                    try analyzeFile(
                        at: URL(fileURLWithPath: path, isDirectory: false), latency: latency
                    ).measures
                }
            }, scanRunning: scanRunning, report: report)
    }

    /// For tests, which stand in for the analysis.
    init(
        cache: MeasuresCache, analyze: @escaping @Sendable (String) async throws -> FileMeasures,
        scanRunning: @escaping @Sendable () async -> Bool,
        report: @escaping @Sendable (Progress) -> Void
    ) {
        self.cache = cache
        self.analyze = analyze
        self.scanRunning = scanRunning
        self.report = report
    }

    /// Starts a run over what the index has left to analyze, or returns the one going. The
    /// task's value is how the run ended. A run paused but not yet stopped is waited for first.
    @discardableResult
    public func start() -> Task<Progress, Never> {
        if let run, !run.task.isCancelled { return run.task }
        runsStarted += 1
        let number = runsStarted
        let previous = run?.task
        let started = Task {
            _ = await previous?.value
            return await pass(number)
        }
        run = (number, started)
        return started
    }

    /// Stops the run going, if any, at once: the file under way is read again by the next run.
    public func pause() {
        run?.task.cancel()
    }

    private func pass(_ number: Int) async -> Progress {
        defer { if run?.number == number { run = nil } }
        var progress = Progress(stage: .analyzing)
        let files: [(path: String, stamp: FileStamp)]
        do {
            files = try await cache.filesToAnalyze()
        } catch {
            logger.error("couldn't list the files to analyze: \(error)")
            progress.stage = .finished
            progress.problem = "\(error)"
            report(progress)
            return progress
        }
        progress.total = files.count
        report(progress)
        func paused() -> Progress {
            progress.stage = .paused
            report(progress)
            return progress
        }
        for file in files {
            while await scanRunning() {
                if progress.stage != .waitingForScan {
                    progress.stage = .waitingForScan
                    report(progress)
                }
                do {
                    try await Task.sleep(nanoseconds: UInt64(Self.scanWaitSeconds * 1e9))
                } catch {
                    return paused()
                }
            }
            if Task.isCancelled { return paused() }
            if progress.stage != .analyzing {
                progress.stage = .analyzing
                report(progress)
            }
            do {
                let measures = try await analyze(file.path)
                try await cache.store(measures, path: file.path, stamp: file.stamp)
            } catch {
                if Task.isCancelled { return paused() }
                logger.error("Analyze Library couldn't analyze \(file.path): \(error)")
                progress.failed += 1
            }
            progress.analyzed += 1
            report(progress)
        }
        progress.stage = .finished
        report(progress)
        return progress
    }
}
