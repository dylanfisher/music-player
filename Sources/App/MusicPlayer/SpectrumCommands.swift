import Analysis
import Commands
import Foundation
import Library
import Log
import Spectrum

private let logger = moduleLogger()

/// Show Spectrum and `music-player analyze` (ADR 0115): both analyze the selection, or the
/// command line's paths, through the analyzer's caches. Analyze Library (ADR 0116) measures
/// the whole library into the same index.
extension AppDelegate {
    func registerSpectrumCommands(_ dispatcher: CommandDispatcher) {
        dispatcher.handle(
            .analyzeLibrary,
            enabled: { [weak self] in
                guard let self, window != nil else { return false }
                return libraryAnalysisStage == nil || libraryAnalysisStage == .paused
            },
            run: { [weak self] in
                guard let self else { return }
                do {
                    let pass = try libraryPass()
                    Task { await pass.start() }
                } catch {
                    browser?.report("Analyze Library: \(error)")
                }
            })
        dispatcher.handle(
            .pauseLibraryAnalysis,
            enabled: { [weak self] in
                [.analyzing, .waitingForScan].contains(self?.libraryAnalysisStage)
            },
            run: { [weak self] in
                guard let pass = self?.libraryAnalysis else { return }
                Task { await pass.pause() }
            })
        dispatcher.handle(
            .showSpectrum,
            enabled: { [weak self] in self?.window != nil && self?.hasSelectedTracks() == true },
            run: { [weak self] in
                self?.withSelectedPaths { paths in
                    guard let self else { return }
                    if let problem = AnalysisRequestError(fileCount: paths.count) {
                        self.browser?.report("Show Spectrum: \(problem)")
                        return
                    }
                    self.spectrumWindows.show(paths.map { ($0, self.spectrumRow(of: $0)) })
                }
            })
    }

    func makeSpectrumWindows() -> SpectrumWindows {
        SpectrumWindows { [weak self] path, progress in
            guard let analyzer = try await self?.fileAnalyzer() else { throw CancellationError() }
            return try await analyzer.result(of: path, progress: progress)
        }
    }

    /// The track's row in the library, for its spectrum's header; nil, so the window names
    /// it by its file, when the index doesn't have it.
    private func spectrumRow(of path: String) -> TrackRow? {
        do {
            return try trackLookup?(path)
        } catch {
            logger.error("couldn't look up \(path) for its spectrum: \(error)")
            return nil
        }
    }

    /// The measures in the index, on a connection of their own, opened on first use.
    private func measuresCache() throws -> MeasuresCache {
        if let measures { return measures }
        let made = try MeasuresCache(databaseURL: libraryFileURL(in: paths.dataDirectory))
        measures = made
        return made
    }

    /// The analyzer, made on first use.
    func fileAnalyzer() throws -> FileAnalyzer {
        if let analyzer { return analyzer }
        let made = FileAnalyzer(measures: try measuresCache(), spectrograms: spectrograms)
        analyzer = made
        return made
    }

    /// Analyze Library, made on first use. It waits while the status bar shows a scan, and
    /// reports to it in the order it went.
    private func libraryPass() throws -> LibraryAnalysis {
        if let libraryAnalysis { return libraryAnalysis }
        let made = LibraryAnalysis(
            cache: try measuresCache(),
            scanRunning: { [weak self] in await self?.browser?.isScanning ?? false },
            report: { [weak self] progress in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.libraryAnalysisReported(progress) }
                }
            })
        libraryAnalysis = made
        return made
    }

    private func libraryAnalysisReported(_ progress: LibraryAnalysis.Progress) {
        switch progress.stage {
        case .analyzing, .waitingForScan, .paused:
            libraryAnalysisStage = progress.stage
            browser?.showAnalysis(
                (progress.text, progress.fraction), stopped: progress.stage == .paused)
        case .finished:
            libraryAnalysisStage = nil
            browser?.showAnalysis(nil, stopped: true)
            // A run that read every file says nothing more: Library Health counts what it found.
            if progress.failed > 0 || progress.problem != nil { browser?.report(progress.text) }
        }
    }

    /// What `music-player analyze` prints for `paths`, or for the selected tracks when there
    /// are none: each file's format line, measures and verdicts, as text or JSON. It shows no
    /// window, so a script can run it over many files.
    func analysisReply(_ paths: [String], json: Bool) async throws -> String {
        let files: [String]
        if paths.isEmpty {
            guard let browser else { throw AnalysisRequestError.noWindow }
            files = try await browser.selectedPaths()
        } else {
            files = paths
        }
        if let problem = AnalysisRequestError(fileCount: files.count) { throw problem }
        let analyzer = try fileAnalyzer()
        var measured: [(path: String, measures: FileMeasures)] = []
        for path in files {
            do {
                measured.append((path, try await analyzer.measures(of: path)))
            } catch {
                throw AnalysisRequestError.failed(path: path, error: "\(error)")
            }
        }
        return json ? try analysisJSON(measured) : analysisReport(measured)
    }
}

enum AnalysisRequestError: Error, Equatable, CustomStringConvertible {
    case noWindow
    case noTracks
    case tooMany(Int)
    case failed(path: String, error: String)

    /// The problem with analyzing `fileCount` files at once, if there is one.
    init?(fileCount: Int) {
        if fileCount == 0 {
            self = .noTracks
        } else if fileCount > AnalysisRules.comparedFiles {
            self = .tooMany(fileCount)
        } else {
            return nil
        }
    }

    var description: String {
        switch self {
        case .noWindow: "the app has no library window to take the selected tracks from"
        case .noTracks: "no tracks are selected"
        case .tooMany(let count):
            "\(count) files are too many: up to \(AnalysisRules.comparedFiles) are analyzed at once"
        case .failed(let path, let error): "couldn't analyze \(path): \(error)"
        }
    }
}
