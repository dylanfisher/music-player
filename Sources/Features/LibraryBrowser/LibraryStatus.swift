import Foundation
import Library

/// The line under the track table: how many tracks it shows, what the watcher is scanning, and
/// how many files and folders have problems, which the owner can open as a list.
struct LibraryStatus: Equatable, Sendable {
    /// Scans running now, by folder path.
    private(set) var scanning: [String: ScanProgress] = [:]
    /// Problems the last scan of each folder had with the folder itself, by folder path.
    private(set) var folderIssues: [String: [ScanIssue]] = [:]
    /// Scans that failed outright, by folder path.
    private(set) var failures: [String: String] = [:]
    /// Files the index stores a warning or failure for.
    var fileIssueCount = 0
    /// What a rebuild of the stats discarded, shown for the session it was found in.
    var notices: [String] = []
    /// What the last playlist import or export couldn't carry over.
    var playlistFileReport: [String] = []

    init() {}

    mutating func apply(_ event: WatcherEvent) {
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
        case .removed:
            break
        }
    }

    /// Whether there's anything for the problems list to show.
    var hasProblems: Bool {
        fileIssueCount > 0 || !folderIssues.isEmpty || !failures.isEmpty || !notices.isEmpty
            || !playlistFileReport.isEmpty
    }

    /// "1,204 tracks · scanning Music: 300 of 1,200 read · 3 files and 1 folder with problems".
    /// `missingCount` is how many of a playlist's tracks aren't in the library. `playCount` is
    /// set on the timeline, which counts plays instead of tracks.
    func text(trackCount: Int, missingCount: Int = 0, playCount: Int? = nil) -> String {
        var parts = [playCount.map { count($0, "play") } ?? tracks(trackCount)]
        if !notices.isEmpty { parts.append("earlier play counts and playlists discarded") }
        if missingCount > 0 { parts.append(tracks(missingCount) + " not in the library") }
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

    /// Every notice and folder problem as a line, for the top of the problems list.
    var problemLines: [String] {
        notices + playlistFileReport
            + failures.sorted { $0.key < $1.key }.map { "\($0.key): the scan failed: \($0.value)" }
            + folderIssues.sorted { $0.key < $1.key }.flatMap { $0.value.map(\.description) }
    }
}

func number(_ value: Int) -> String {
    NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
}

/// "1 track", "1,204 tracks": the one spelling of the noun every count of tracks uses.
func tracks(_ value: Int) -> String { count(value, "track") }

func count(_ value: Int, _ noun: String) -> String {
    "\(number(value)) \(noun)\(value == 1 ? "" : "s")"
}
