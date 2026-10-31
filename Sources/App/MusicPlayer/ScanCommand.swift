import Foundation
import Library
import Metadata
import SQLite
import Settings

/// Returns to the start of the line and clears it, so progress rewrites one line in place.
let eraseLine = "\r\u{1B}[K"

/// `MusicPlayer --scan <folder> [--db <path>] [--readers <n>]`: scans one folder into the
/// library database, printing progress and a summary, and writes every warned or failed file to
/// a text file beside the database. Safe to rerun; the second run measures a rescan with no
/// changes. `readers` fixes how many files a network scan reads at once, instead of tuning it.
func scanCommand(folder: String, databasePath: String?, readers: Int?) throws {
    let path = URL(fileURLWithPath: folder).standardizedFileURL.path
    // Unknown only when the folder is missing.
    let isLocal = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsLocalKey]))?
        .volumeIsLocal
    let databaseURL: URL
    if let databasePath {
        databaseURL = URL(fileURLWithPath: databasePath)
    } else {
        // The app removes files outside its watched folders at launch, so a scan into its own
        // index of anything else would be undone.
        let settingsURL = try defaultSettingsFileURL()
        let settings = try SettingsStore(AppSettings(), fileURL: settingsURL)
        try requireWatched(path, in: settings[\.watchedFolders])
        databaseURL = defaultLibraryFileURL(settingsFileURL: settingsURL)
    }
    if readers != nil, isLocal == nil {
        FileHandle.standardError.write(Data("error: \(path) doesn't exist\n".utf8))
        exit(1)
    }
    if readers != nil, isLocal != false {
        // A local scan always reads on every core, so the flag would silently do nothing.
        FileHandle.standardError.write(
            Data("error: --readers only applies to a folder on a network volume\n".utf8))
        exit(1)
    }
    print(
        "scanning \(path) (\(isLocal == false ? "network" : "local") volume) into \(databaseURL.path)"
    )

    let (stream, continuation) = ScanProgress.makeStream()
    let started = Date()
    let printed = DispatchSemaphore(value: 0)
    // Detached, because the caller runs on the main actor, which the scan blocks.
    Task.detached {
        var lastPrint = Date.distantPast
        for await progress in stream where Date().timeIntervalSince(lastPrint) >= 0.25 {
            lastPrint = Date()
            printProgress(progress, since: started)
        }
        printed.signal()
    }
    let summary = try LibraryScanner(databaseURL: databaseURL, networkReaders: readers).scan(
        WatchedFolder(path: path, kind: isLocal == false ? .network : .local),
        progress: continuation)
    continuation.finish()
    printed.wait()
    let elapsed = Date().timeIntervalSince(started)
    print(eraseLine, terminator: "")

    let index = try LibraryIndex(at: databaseURL)
    let issues = try index.fileIssues()
    let reportURL = databaseURL.deletingPathExtension()
        .appendingPathExtension("issues.txt")
    try report(summary, issues, folder: path).write(
        to: reportURL, atomically: true, encoding: .utf8)

    var lines = [
        String(
            format: "scanned %@ in %.1f s%@", path, elapsed, summary.cancelled ? " (cancelled)" : ""
        ),
        "  tracks in the library: \(try index.trackCount())",
        "  read: \(summary.read) new or changed (\(summary.failed) failed),"
            + " unchanged: \(summary.unchanged), removed: \(summary.removed)",
        String(
            format: "  %.0f files/s; %d other files skipped",
            Double(summary.read + summary.unchanged) / max(elapsed, 0.001), summary.otherFiles),
        "  " + describe(summary.readers)
            + String(format: ", %.0f files/s read", Double(summary.read) / max(elapsed, 0.001)),
        "  warnings by kind: " + counts(issues, MetadataWarning.Kind.allCases) { .warning($0) },
        "  failures by kind: " + counts(issues, MetadataError.Kind.allCases) { .failure($0) },
    ]
    lines += summary.issues.map { "  folder issue: \($0)" }
    lines += [
        String(
            format: "  database: %.1f MB", Double(try Database.sizeBytes(at: databaseURL)) / 1e6),
        "  every warned or failed file: \(reportURL.path)",
    ]
    print(lines.joined(separator: "\n"))
}

private func printProgress(_ progress: ScanProgress, since started: Date) {
    let elapsed = max(Date().timeIntervalSince(started), 0.001)
    let line =
        switch progress.stage {
        case .walking:
            String(
                format: "walking: %d audio files found, %d of %d read, %.0f files/s",
                progress.found, progress.read, progress.toRead, Double(progress.found) / elapsed)
        case .reading:
            String(
                format: "reading: %d of %d (%d unchanged), %d failed, %.0f files/s",
                progress.read, progress.toRead, progress.unchanged, progress.failed,
                Double(progress.read) / elapsed)
        }
    let load = progress.load
    print(
        eraseLine + line
            + ", \(load.readers) readers (\(load.idleReaders) idle), \(load.listers) listers,"
            + " \(load.queued) queued",
        terminator: "")
    fflush(stdout)
}

/// "readers: 4→8→16→12 (held)", with a long trace cut to its start and end.
private func describe(_ readers: ScanSummary.Readers?) -> String {
    switch readers {
    case nil: return "readers: none, the scan stopped before reading"
    case .fixed(let count): return "readers: \(count) (fixed)"
    case .tuned(let levels, let climbing):
        let shown =
            levels.count > 12
            ? levels.prefix(6).map(String.init) + ["…"] + levels.suffix(5).map(String.init)
            : levels.map(String.init)
        return "readers: " + shown.joined(separator: "→")
            + (climbing ? " (still climbing)" : " (held)")
    }
}

/// "badNumber 3, badText 1", or "none".
private func counts<Kind: RawRepresentable<String>>(
    _ issues: [FileIssue], _ kinds: [Kind], _ problem: (Kind) -> FileIssue.Problem
) -> String {
    let counted = kinds.compactMap { kind in
        let count = issues.filter { $0.problem == problem(kind) }.count
        return count == 0 ? nil : "\(kind.rawValue) \(count)"
    }
    return counted.isEmpty ? "none" : counted.joined(separator: ", ")
}

private func report(_ summary: ScanSummary, _ issues: [FileIssue], folder: String) -> String {
    var lines = ["Warnings and failures in the library, after scanning \(folder)", ""]
    lines += summary.issues.map { "folder: \($0)" }
    lines += issues.map(\.description)
    if summary.issues.isEmpty && issues.isEmpty { lines.append("none") }
    return lines.joined(separator: "\n") + "\n"
}
