import DisplayText
import Foundation
import Library
import Settings

/// The bar under the track table: how many tracks it shows, what the watcher is scanning, and
/// how many files and folders have problems, which the owner can open as a list.
struct LibraryStatus: Equatable, Sendable {
    /// Scans running now, by folder path.
    private(set) var scanning: [String: ScanProgress] = [:]
    /// The folder whose scan Pause Scan holds, until Resume Scan or the scan's end.
    private(set) var pausedScan: String?
    /// Whether this launch rebuilt the index, so each folder's scan is the rebuild's until one
    /// of its scans ends (ADR 0136).
    var rebuildingIndex = false
    /// The folders a scan has finished for since launch, read through or failed; a stopped one
    /// starts again as the rebuild's.
    private var scannedFolders: Set<String> = []
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
    var playlistFileReport: [Problem] = []
    /// What the last drop of files on the window couldn't add.
    var addedFilesReport: [Problem] = []
    /// What the last organizing of files in the library folder didn't move (ADR 0164).
    var organizedReport: [Problem] = []
    /// The lines of the last move list imported that moved nothing.
    var importedMovesReport: [Problem] = []
    /// What the health check shown found that the table can't list, and how many such items.
    var healthProblems: [Problem] = []
    var healthOtherCount = 0
    /// The lines the user dismissed, which the problems list leaves out.
    var dismissed: Set<String> = []
    /// What the tag editor says of a save under way, such as "Saving tags: 3 of 20", and how
    /// far along it is, from 0 to 1.
    var savingText: String?
    var savingFraction = 0.0
    /// What a drop's copy into the library folder says while it runs, such as "Copying into
    /// the library folder: 3 of 20", and how far along it is.
    var copyingText: String?
    var copyingFraction = 0.0
    /// What Keep Files Organized or Organize Selected Files says while it renames, such as
    /// "Organizing files: 12 left · Album/01 Song.flac", and how far along it is (ADR 0175).
    var organizingText: String?
    var organizingFraction = 0.0
    /// What Analyze Library says while it runs or is paused, such as "Analyzing library: 40 of
    /// 1,200", and how far along it is.
    var analysisText: String?
    var analysisFraction = 0.0

    init() {}

    mutating func apply(_ event: WatcherEvent) {
        switch event {
        case .scanning(let folder, let progress):
            scanning[folder] = progress
        case .scanPaused(let folder, let paused):
            if paused {
                pausedScan = folder
                // Paused before its first progress, it still shows.
                if scanning[folder] == nil { scanning[folder] = ScanProgress() }
            } else if pausedScan == folder {
                pausedScan = nil
            }
        case .scanned(let folder, let summary):
            scanEnded(folder)
            scannedFolders.insert(folder)
            failures[folder] = nil
            folderIssues[folder] = summary.issues.isEmpty ? nil : summary.issues
        case .scanFailed(let folder, let reason):
            scanEnded(folder)
            scannedFolders.insert(folder)
            failures[folder] = reason
        case .scanStopped(let folder):
            scanEnded(folder)
        case .synced(let report):
            syncProblems = report.problems
        case .syncFailed(let reason):
            syncProblems = ["the sync failed: \(reason)"]
        case .removed, .folders, .keptIndex, .launchScansEnded, .edited:
            break
        }
    }

    private mutating func scanEnded(_ folder: String) {
        scanning[folder] = nil
        if pausedScan == folder { pausedScan = nil }
    }

    /// Whether there's anything for the problems list to show. `fileIssueCount` counts only
    /// the files with a problem not dismissed.
    var hasProblems: Bool { fileIssueCount > 0 || !problems.isEmpty }

    /// "1,204 tracks, 5.1 GiB, 3 days 2 hours · 2 tracks not in the library": what the list shown
    /// holds, with the totals of `selection` as `shown` asks, written by `formats`.
    /// `missingCount` is how many of a playlist's tracks aren't in the library, appended unless
    /// the template places it. `playCount` is set on the timeline, which counts plays instead
    /// of tracks, and `playSpan` when it lists only a span's.
    func summary(
        list: TrackTotals, selection: TrackTotals, shown: StatusTotals,
        formats: TotalsFormats = .defaults, missingCount: Int = 0, playCount: Int? = nil,
        playSpan: PlaySpan? = nil
    ) -> String {
        let template = formats.template(shown, selected: selection.count > 0)
        var parts = [
            playCount.map { plays($0) + (playSpan.map { ", " + $0.title() } ?? "") }
                ?? totals(template, list, selection, missingCount: missingCount)
        ]
        let placed = playCount == nil && template.parts.contains(.token(.missing))
        if missingCount > 0, !placed {
            parts.append(tracks(missingCount) + " not in the library")
        }
        if healthOtherCount > 0 {
            parts.append(count(healthOtherCount, "more item") + " with no track to list")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// `template` filled with the list's totals and the selection's, which are empty while
    /// nothing is selected.
    private func totals(
        _ template: TotalsTemplate, _ list: TrackTotals, _ selection: TrackTotals,
        missingCount: Int
    ) -> String {
        let selected = selection.count > 0 ? selection : nil
        return template.fill { token in
            switch token {
            case .tracks: tracks(list.count)
            case .size: binarySize(list.sizeBytes)
            case .duration: spokenDuration(list.durationSeconds)
            case .albums: albums(list.albumCount)
            case .selectedTracks: selected.map { tracks($0.count) }
            case .selectedSize: selected.map { binarySize($0.sizeBytes) }
            case .selectedDuration: selected.map { spokenDuration($0.durationSeconds) }
            case .selectedAlbums: selected.map { albums($0.albumCount) }
            case .missing: missingCount > 0 ? tracks(missingCount) : nil
            }
        }
    }

    /// "Scanning Music: 300 of 1,200 read", a part per folder, and "Scan paused: Music: 300 of
    /// 1,200 read" for the one Pause Scan holds, and "Rebuilding the index: Music: 300 of 1,200
    /// read" for a folder's scan that refills a rebuilt index; nil while nothing scans.
    var scanText: String? {
        guard !scanning.isEmpty else { return nil }
        let parts = scanning.sorted(by: { $0.key < $1.key }).map { folder, progress in
            let name = (folder as NSString).lastPathComponent
            return (
                folder,
                progress.toRead == 0
                    ? "\(name): \(number(progress.found)) files checked"
                    : "\(name): \(number(progress.read)) of \(number(progress.toRead)) read"
            )
        }
        let running = parts.filter { $0.0 != pausedScan }
        let rebuilding = running.filter { rebuildingIndex && !scannedFolders.contains($0.0) }
        let plain = running.filter { !rebuilding.map(\.0).contains($0.0) }.map(\.1)
        let paused = parts.filter { $0.0 == pausedScan }.map(\.1)
        return
            ((rebuilding.isEmpty
            ? [] : ["Rebuilding the index: " + rebuilding.map(\.1).joined(separator: " · ")])
            + (plain.isEmpty ? [] : ["Scanning " + plain.joined(separator: " · ")])
            + paused.map { "Scan paused: " + $0 }).joined(separator: " · ")
    }

    /// The scans' text, a tag save's, a copy's and an organize's, the first part of the
    /// activity line.
    var scanAndSaveText: String? {
        let parts = [scanText, savingText, copyingText, organizingText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Whether Pause Scan holds the scan the status bar shows, so its button resumes it.
    var scanIsPaused: Bool { pausedScan != nil }

    /// How much of what the scans have to read they've read, from 0 to 1. Nil while nothing
    /// scans, or while a scan is still listing folders, since what it has to read still grows;
    /// 0 for that while the scan shown is paused, so its bar stands still, empty.
    var scanFraction: Double? {
        guard !scanning.isEmpty else { return nil }
        guard scanning.values.allSatisfy({ $0.stage == .reading && $0.toRead > 0 }) else {
            return isScanning ? nil : 0
        }
        let values = scanning.values
        return Double(values.map(\.read).reduce(0, +)) / Double(values.map(\.toRead).reduce(0, +))
    }

    /// The line beside the bar that fills: the scans, a tag save, a copy, an organize and
    /// Analyze Library, any of them; nil while none runs.
    var activityText: String? {
        let parts = [scanAndSaveText, analysisText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// How far that bar is filled: the scans' fraction while any scans, else the save's, else
    /// the copy's, else the organize's, else the analysis's. Nil for a bar that moves on its
    /// own, or none.
    var activityFraction: Double? {
        if scanText != nil { return scanFraction }
        if savingText != nil { return savingFraction }
        if copyingText != nil { return copyingFraction }
        if organizingText != nil { return organizingFraction }
        return analysisText.map { _ in analysisFraction }
    }

    /// Whether a scan is under way, which Analyze Library waits for; a paused scan reads
    /// nothing, so it doesn't count.
    var isScanning: Bool { scanning.keys.contains { $0 != pausedScan } }

    /// "3 files and 1 folder with problems", the title of the button that lists them. Notices
    /// that count nothing still have a list to show. Nil when there's nothing to list.
    var problemsTitle: String? {
        guard hasProblems else { return nil }
        let folders = Set(
            folderLines.filter { !dismissed.contains($0.problem.line) }.map(\.folder)
        ).count
        var problems: [String] = []
        if fileIssueCount > 0 { problems.append(files(fileIssueCount)) }
        if folders > 0 { problems.append(count(folders, "folder")) }
        if syncProblems.contains(where: { !dismissed.contains($0) }) {
            problems.append("the sync")
        }
        guard !problems.isEmpty else { return "Show Problems" }
        let text = problems.joined(separator: " and ") + " with problems"
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Every notice and folder problem not dismissed, for the top of the problems list.
    var problems: [Problem] {
        let reports =
            notices.map { Problem($0, kind: ProblemKind.notice) }
            + playlistFileReport.map { $0.kinded(ProblemKind.imported) }
            + addedFilesReport.map { $0.kinded(ProblemKind.added) }
            + organizedReport.map { $0.kinded(ProblemKind.organized) }
            + importedMovesReport.map { $0.kinded(ProblemKind.movesImported) }
        return
            (reports + healthProblems + syncProblems.map { Problem($0, kind: ProblemKind.sync) }
            + folderLines.map(\.problem)).filter { !dismissed.contains($0.line) }
    }

    var problemLines: [String] { problems.map(\.line) }

    /// Each folder's failed scan and the problems its last scan had.
    private var folderLines: [(folder: String, problem: Problem)] {
        failures.sorted { $0.key < $1.key }.map {
            (
                $0.key,
                Problem(
                    "\($0.key): the scan failed: \($0.value)", kind: ProblemKind.scanFailed,
                    path: $0.key, detail: $0.value)
            )
        }
            + folderIssues.sorted { $0.key < $1.key }.flatMap { folder, issues in
                issues.map { (folder, Problem($0)) }
            }
    }
}

/// "1 play", "1,204 plays", as the timeline and Listening Stats count them.
func plays(_ value: Int) -> String { count(value, "play") }
