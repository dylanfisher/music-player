import Foundation
import Library
import Metadata
import Settings

/// `MusicPlayer --scan <folder> [--db <path>]`: scans one folder into the library database,
/// printing progress and a summary, and writes every warned or failed file to a text file beside
/// the database. Safe to rerun; the second run measures a rescan with no changes.
func scanCommand(folder: String, databasePath: String?) throws {
    let path = URL(fileURLWithPath: folder).standardizedFileURL.path
    // Unknown only when the folder is missing, which the scan reports as such.
    let isLocal = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsLocalKey]))?
        .volumeIsLocal
    let databaseURL =
        try databasePath.map { URL(fileURLWithPath: $0) }
        ?? defaultLibraryFileURL(settingsFileURL: try defaultSettingsFileURL())
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
    let summary = try LibraryScanner(databaseURL: databaseURL).scan(
        WatchedFolder(path: path, kind: isLocal == false ? .network : .local),
        progress: continuation)
    continuation.finish()
    printed.wait()
    let elapsed = Date().timeIntervalSince(started)
    print("\r\u{1B}[K", terminator: "")

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
        "  warnings by kind: " + counts(issues, MetadataWarning.Kind.allCases) { .warning($0) },
        "  failures by kind: " + counts(issues, MetadataError.Kind.allCases) { .failure($0) },
    ]
    lines += summary.issues.map { "  folder issue: \($0)" }
    lines += [
        String(format: "  database: %.1f MB", try databaseMegabytes(databaseURL)),
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
                format: "walking: %d audio files found, %.0f files/s", progress.found,
                Double(progress.found) / elapsed)
        case .reading:
            String(
                format: "reading: %d of %d, %d failed, %.0f files/s", progress.read,
                progress.toRead, progress.failed, Double(progress.read) / elapsed)
        }
    print("\r\u{1B}[K" + line, terminator: "")
    fflush(stdout)
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

/// The database and its write-ahead log.
private func databaseMegabytes(_ url: URL) throws -> Double {
    try [url.path, url.path + "-wal"].reduce(0.0) { total, path in
        guard FileManager.default.fileExists(atPath: path) else { return total }
        let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int ?? 0
        return total + Double(size) / 1e6
    }
}
