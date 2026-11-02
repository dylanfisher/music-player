import Foundation
import Library
import Settings

/// The bar under the track table: how many tracks it shows, what the watcher is scanning, and
/// how many files and folders have problems, which the owner can open as a list.
struct LibraryStatus: Equatable, Sendable {
    /// Scans running now, by folder path.
    private(set) var scanning: [String: ScanProgress] = [:]
    /// Problems the last scan of each folder had with the folder itself, by folder path.
    private(set) var folderIssues: [String: [ScanIssue]] = [:]
    /// Scans that failed outright, by folder path.
    private(set) var failures: [String: String] = [:]
    /// What the last sync found wrong with the sync folder or the other Macs' logs.
    private(set) var syncProblems: [String] = []
    /// Files the index stores a warning or failure for.
    var fileIssueCount = 0
    /// What a rebuild of the stats discarded, shown for the session it was found in.
    var notices: [String] = []
    /// What the last playlist import or export couldn't carry over.
    var playlistFileReport: [String] = []
    /// What the health check shown found that the table can't list, and how many such items.
    var healthLines: [String] = []
    var healthOtherCount = 0

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
        case .synced(let report):
            syncProblems = report.problems
        case .syncFailed(let reason):
            syncProblems = ["the sync failed: \(reason)"]
        case .removed, .folders, .keptIndex, .launchScansEnded:
            break
        }
    }

    /// Whether there's anything for the problems list to show.
    var hasProblems: Bool {
        fileIssueCount > 0 || !folderIssues.isEmpty || !failures.isEmpty || !notices.isEmpty
            || !playlistFileReport.isEmpty || !healthLines.isEmpty || !syncProblems.isEmpty
    }

    /// "1,204 tracks, 5.1 GiB, 3 days 2 hours · 2 tracks not in the library": what the list shown
    /// holds, with the totals of `selection` as `shown` asks. `missingCount` is how many of a
    /// playlist's tracks aren't in the library. `playCount` is set on the timeline, which counts
    /// plays instead of tracks.
    func summary(
        list: TrackTotals, selection: TrackTotals, shown: StatusTotals, missingCount: Int = 0,
        playCount: Int? = nil
    ) -> String {
        var parts = [playCount.map { count($0, "play") } ?? totals(list, selection, shown)]
        if !notices.isEmpty { parts.append("earlier play counts and playlists discarded") }
        if missingCount > 0 { parts.append(tracks(missingCount) + " not in the library") }
        if healthOtherCount > 0 {
            parts.append(count(healthOtherCount, "more item") + " with no track to list")
        }
        return parts.joined(separator: " · ")
    }

    /// The list's totals, the selection's, or both, falling back to the list's while nothing is
    /// selected.
    private func totals(_ list: TrackTotals, _ selection: TrackTotals, _ shown: StatusTotals)
        -> String
    {
        guard selection.count > 0 else { return list.text() }
        return switch shown {
        case .listAndSelection: "\(list.text()) (\(selection.text(selected: true)))"
        case .list: list.text()
        case .selection: selection.text(selected: true)
        }
    }

    /// "Scanning Music: 300 of 1,200 read", a part per folder; nil while nothing scans.
    var scanText: String? {
        guard !scanning.isEmpty else { return nil }
        let parts = scanning.sorted(by: { $0.key < $1.key }).map { folder, progress in
            let name = (folder as NSString).lastPathComponent
            return progress.toRead == 0
                ? "\(name): \(number(progress.found)) files checked"
                : "\(name): \(number(progress.read)) of \(number(progress.toRead)) read"
        }
        return "Scanning " + parts.joined(separator: " · ")
    }

    /// How much of what the scans have to read they've read, from 0 to 1. Nil while nothing
    /// scans, or while a scan is still listing folders, since what it has to read still grows.
    var scanFraction: Double? {
        guard !scanning.isEmpty,
            scanning.values.allSatisfy({ $0.stage == .reading && $0.toRead > 0 })
        else { return nil }
        let values = scanning.values
        return Double(values.map(\.read).reduce(0, +)) / Double(values.map(\.toRead).reduce(0, +))
    }

    /// "3 files and 1 folder with problems", the title of the button that lists them. Notices
    /// that count nothing still have a list to show. Nil when there's nothing to list.
    var problemsTitle: String? {
        guard hasProblems else { return nil }
        let folders = Set(folderIssues.keys).union(failures.keys).count
        var problems: [String] = []
        if fileIssueCount > 0 { problems.append(count(fileIssueCount, "file")) }
        if folders > 0 { problems.append(count(folders, "folder")) }
        if !syncProblems.isEmpty { problems.append("the sync") }
        guard !problems.isEmpty else { return "Show Problems" }
        let text = problems.joined(separator: " and ") + " with problems"
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Every notice and folder problem as a line, for the top of the problems list.
    var problemLines: [String] {
        notices + playlistFileReport + healthLines + syncProblems
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
