import DisplayText
import Library
import Log

private let logger = moduleLogger()

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
            status.latestRescan += 1
            let rescanned = status.latestRescan
            status.rescanningText = "Reading \(files(paths.count)) again"
            showStatus()
            rescan(paths) { result in
                Task { @MainActor in self.finishRescanning(result, rescanned) }
            }
        }
    }

    /// The watcher answers in order, so the report is the last one to finish; the status line
    /// is only the last one begun's, so an earlier one's end doesn't hide that one running.
    private func finishRescanning(_ result: Result<ScanSummary, any Error>, _ rescanned: Int) {
        let latest = rescanned == status.latestRescan
        if latest { status.rescanningText = nil }
        switch result {
        case .success(let summary):
            let rows = rescannedProblems(summary)
            if latest {
                finish(rescannedSummary(summary), rows, as: \.rescannedReport)
            } else {
                status.rescannedReport = rows
                showStatus()
            }
        case .failure(let error):
            // The last rescan's problems would read as this one's.
            status.rescannedReport = []
            showStatus()
            let message = "couldn't read the selected files again: \(error)"
            if latest { report(message) } else { logger.error("\(message)") }
        }
    }
}

/// The Problems window's rows for what `summary` couldn't read, the issues beyond the scanner's
/// cap counted in one row.
func rescannedProblems(_ summary: ScanSummary) -> [Problem] {
    summary.issues.map { Problem($0) }
        + (summary.unlistedIssues > 0
            ? [
                Problem(
                    "\(files(summary.unlistedIssues)) more couldn't be read again, not listed",
                    kind: ProblemKind.folder(.unreadable))
            ] : [])
}

/// "Read 12 files again; 1 problem": a file read whose tags failed counts, with each one that
/// couldn't be read at all.
func rescannedSummary(_ summary: ScanSummary) -> String {
    let line = "Read \(files(summary.read)) again"
    let problems = summary.failed + summary.issues.count + summary.unlistedIssues
    return problems == 0 ? line : line + "; " + problemCount(problems)
}
