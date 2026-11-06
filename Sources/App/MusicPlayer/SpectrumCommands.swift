import Analysis
import Commands
import Foundation
import Library
import Log
import Spectrum

private let logger = moduleLogger()

/// Show Spectrum and `music-player analyze` (ADR 0115): both analyze the selection, or the
/// command line's paths, through the analyzer's caches.
extension AppDelegate {
    func registerSpectrumCommands(_ dispatcher: CommandDispatcher) {
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

    /// The analyzer, made on first use: it opens a connection of its own to the library.
    func fileAnalyzer() throws -> FileAnalyzer {
        if let analyzer { return analyzer }
        let made = FileAnalyzer(
            measures: try MeasuresCache(databaseURL: libraryFileURL(in: paths.dataDirectory)),
            spectrograms: spectrograms)
        analyzer = made
        return made
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
