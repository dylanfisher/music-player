import Analysis
import Foundation
import Library

/// Show Spectrum and `music-player analyze` (ADR 0115): both analyze the selection, or the
/// command line's paths, through the analyzer's caches.
extension AppDelegate {
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
