import Foundation
import Library

/// The line under the track table: how many tracks it shows, what the watcher is scanning, and
/// how many files and folders have problems, which the owner can open as a list.
public struct LibraryStatus: Equatable, Sendable {
    /// Scans running now, by folder path.
    public private(set) var scanning: [String: ScanProgress] = [:]
    /// Problems the last scan of each folder had with the folder itself, by folder path.
    public private(set) var folderIssues: [String: [ScanIssue]] = [:]
    /// Scans that failed outright, by folder path.
    public private(set) var failures: [String: String] = [:]
    /// Files the index stores a warning or failure for.
    public var fileIssueCount = 0

    public init() {}

    public mutating func apply(_ event: WatcherEvent) {
        switch event {
        case .scanning(let folder, let progress):
            scanning[folder] = progress
        case .scanned(let folder, let summary):
            scanning[folder] = nil
            failures[folder] = nil
            folderIssues[folder] = summary.issues.isEmpty ? nil : summary.issues
        case .scanFailed(let folder, let reason):
            scanning[folder] = nil
            failures[folder] = reason
        }
    }

    /// Whether there's anything for the problems list to show.
    public var hasProblems: Bool {
        fileIssueCount > 0 || !folderIssues.isEmpty || !failures.isEmpty
    }

    /// "1,204 tracks · scanning Music: 300 of 1,200 read · 3 files and 1 folder with problems".
    public func text(trackCount: Int) -> String {
        var parts = [count(trackCount, "track")]
        for (folder, progress) in scanning.sorted(by: { $0.key < $1.key }) {
            let name = (folder as NSString).lastPathComponent
            parts.append(
                progress.toRead == 0
                    ? "scanning \(name): \(number(progress.found)) files checked"
                    : "scanning \(name): \(number(progress.read)) of \(number(progress.toRead)) read"
            )
        }
        let folders = Set(folderIssues.keys).union(failures.keys).count
        var problems: [String] = []
        if fileIssueCount > 0 { problems.append(count(fileIssueCount, "file")) }
        if folders > 0 { problems.append(count(folders, "folder")) }
        if !problems.isEmpty {
            parts.append(problems.joined(separator: " and ") + " with problems")
        }
        return parts.joined(separator: " · ")
    }

    /// Every folder problem as a line, for the top of the problems list.
    public var folderLines: [String] {
        failures.sorted { $0.key < $1.key }.map { "\($0.key): the scan failed: \($0.value)" }
            + folderIssues.sorted { $0.key < $1.key }.flatMap { $0.value.map(\.description) }
    }
}

private func number(_ value: Int) -> String {
    NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
}

private func count(_ value: Int, _ noun: String) -> String {
    "\(number(value)) \(noun)\(value == 1 ? "" : "s")"
}
