import Analysis
import AppKit
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
            title: { [weak self] in self?.analyzeLibraryTitle ?? "" },
            run: { [weak self] in self?.analyzeLibrary() })
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
                    self.spectrumWindows.show(paths.map { ($0, self.spectrumTitle(of: $0)) })
                }
            })
    }

    func makeSpectrumWindows() -> SpectrumWindows {
        SpectrumWindows { [weak self] path, progress in
            guard let analyzer = try await self?.fileAnalyzer() else { throw CancellationError() }
            return try await analyzer.result(of: path, progress: progress)
        }
    }

    /// The track's title from the library, or its file's name.
    private func spectrumTitle(of path: String) -> String {
        var row: TrackRow?
        do {
            row = try trackLookup?(path)
        } catch {
            logger.error("couldn't look up \(path) for its spectrum: \(error)")
        }
        return row?.title
            ?? URL(fileURLWithPath: path, isDirectory: false).deletingPathExtension()
            .lastPathComponent
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
            browser?.showAnalysis(progress, stopped: progress.stage == .paused)
        case .finished:
            libraryAnalysisStage = nil
            browser?.showAnalysis(nil, stopped: true)
            // A run that read every file says nothing more: Library Health counts what it found.
            if progress.failed > 0 || progress.problem != nil { browser?.report(progress.text) }
        }
        if [.paused, .finished].contains(progress.stage) { showLibraryAnalysisStanding() }
    }

    /// Analyze Library's title as it would run now (ADR 0119).
    var analyzeLibraryTitle: String {
        libraryAnalysisStage == nil && libraryAnalysisEveryFileTried
            ? AppCommands.analyzeLibraryAgainTitle : AppCommands.title(of: .analyzeLibrary)
    }

    /// Analyze Library: carries on with what's left, or, once every file was tried, asks
    /// before reading the whole library again.
    private func analyzeLibrary() {
        let pass: LibraryAnalysis
        do {
            pass = try libraryPass()
        } catch {
            browser?.report("Analyze Library: \(error)")
            return
        }
        Task { [weak self] in
            let standing: LibraryAnalysis.Standing
            do {
                standing = try await pass.standing()
            } catch {
                self?.browser?.report("Analyze Library: \(error)")
                return
            }
            guard standing.everyFileTried else {
                await pass.start()
                return
            }
            self?.confirmAnalyzingAgain(pass)
        }
    }

    private func confirmAnalyzingAgain(_ pass: LibraryAnalysis) {
        guard let window = window?.window else { return }
        let alert = NSAlert()
        alert.messageText = "Analyze the whole library again?"
        alert.informativeText =
            "Every file has been analyzed. Analyzing again reads every file once more, which"
            + " takes hours on a network share. Each file keeps its measures until its new ones"
            + " are stored."
        alert.addButton(withTitle: "Analyze Again")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { await pass.start(again: true) }
        }
    }

    /// Asks the pass where it stands, while no run goes, and shows it: the title Analyze
    /// Library has, and a run left unfinished at the last quit, as paused.
    func showLibraryAnalysisStanding() {
        guard libraryAnalysisStage == nil || libraryAnalysisStage == .paused else { return }
        let pass: LibraryAnalysis
        do {
            pass = try libraryPass()
        } catch {
            logger.error("couldn't open the measures to see where Analyze Library stands: \(error)")
            return
        }
        Task { [weak self] in
            let standing: LibraryAnalysis.Standing
            do {
                standing = try await pass.standing()
            } catch {
                logger.error("couldn't read where Analyze Library stands: \(error)")
                return
            }
            guard let self, libraryAnalysisStage == nil || libraryAnalysisStage == .paused
            else { return }
            libraryAnalysisEveryFileTried = standing.everyFileTried
            if libraryAnalysisStage == nil, let paused = standing.paused {
                libraryAnalysisStage = .paused
                browser?.showAnalysis(paused)
            }
            browser?.analyzeLibraryTitle = analyzeLibraryTitle
        }
    }

    /// `events`, and the pass's standing read again after a scan or a removal changed the
    /// library, since its files changed.
    func analysisStandingFollowing(
        _ events: @escaping @Sendable (WatcherEvent) -> Void
    ) -> @Sendable (WatcherEvent) -> Void {
        { [weak self] event in
            events(event)
            let changed: Bool =
                switch event {
                case .scanned(_, let summary): summary.read > 0 || summary.removed > 0
                case .removed: true
                default: false
                }
            guard changed else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.showLibraryAnalysisStanding() }
            }
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
