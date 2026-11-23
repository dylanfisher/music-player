import DisplayText
import Library

/// What reads files again for Rescan Selected Files: `LibraryWatcher.rescan(files:done:)`, which
/// tests stand in for.
public typealias FileRescan =
    @MainActor ([String], @escaping @Sendable (Result<ScanSummary, any Error>) -> Void) -> Void

extension LibraryBrowser {
    /// What a command says when `selectedPaths` throws.
    public static let unreadSelection = "couldn't read the selected tracks"

    /// Rescan Selected Files: hands the selected tracks' paths to `rescan`, which reads them
    /// again whatever their size and mtime say, then says how many it read and lists the files
    /// it couldn't, as a folder scan's problems are listed (ADR 0221).
    public func rescanSelection(through rescan: @escaping FileRescan) {
        Task {
            let paths: [String]
            do {
                paths = try await selectedPaths()
            } catch {
                return reportCommand(Self.unreadSelection, error)
            }
            guard !paths.isEmpty else { return }
            show(failure: "Reading \(files(paths.count)) again")
            rescan(paths) { result in
                Task { @MainActor in self.finishRescanning(result) }
            }
        }
    }

    private func finishRescanning(_ result: Result<ScanSummary, any Error>) {
        switch result {
        case .success(let summary):
            finish(
                rescannedSummary(summary), summary.issues.map { Problem($0) },
                as: \.rescannedReport)
        case .failure(let error):
            report("couldn't read the selected files again: \(error)")
        }
    }
}

/// "Read 12 files again; 1 problem": a file read whose tags failed counts, with each one that
/// couldn't be read at all.
func rescannedSummary(_ summary: ScanSummary) -> String {
    let line = "Read \(files(summary.read)) again"
    let problems = summary.failed + summary.issues.count
    return problems == 0 ? line : line + "; " + problemCount(problems)
}
