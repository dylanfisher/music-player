import Foundation
import Library
import Log
import SQLite

private let logger = moduleLogger()

/// Restore…: unpacks `snapshot` beside the index at `databaseURL`, checks that SQLite reads
/// it whole, snapshots the current index into `snapshotFolder`, and leaves a marker naming the
/// snapshot, so the next launch puts the unpacked file in the index's place before it opens
/// (ADR 0142). A snapshot that doesn't unpack, or unpacks damaged, throws with nothing
/// replaced. The current index's snapshot comes after the check, since on the day of the
/// chosen snapshot it replaces that file.
public func prepareRestore(
    of snapshot: URL, databaseURL: URL, snapshotFolder: URL, now: Date
) throws {
    let restoring = restoringFileURL(databaseURL)
    for suffix in ["", Database.walSuffix, Database.shmSuffix] {
        try removeIfThere(URL(fileURLWithPath: restoring.path + suffix, isDirectory: false))
    }
    do {
        try GzipFile.decompress(snapshot, to: restoring)
        try checkWhole(restoring, name: snapshot.lastPathComponent)
    } catch {
        try removeIfThere(restoring)
        throw error
    }
    try writeSnapshot(of: LibraryIndex(at: databaseURL), into: snapshotFolder, on: now)
    try Data((snapshot.lastPathComponent + "\n").utf8).write(
        to: restoreMarkerURL(databaseURL), options: .atomic)
}

/// At launch, before the index opens: when a restore was prepared, moves the index aside, as
/// `library.sqlite.replaced-<stamp>`, and the unpacked snapshot into its place. Returns the
/// snapshot's name, or nil when no restore was waiting.
public func applyPendingRestore(databaseURL: URL) throws -> String? {
    let marker = restoreMarkerURL(databaseURL)
    let named: String
    do {
        named = try String(contentsOf: marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch CocoaError.fileReadNoSuchFile {
        return nil
    }
    let restoring = restoringFileURL(databaseURL)
    guard FileManager.default.fileExists(atPath: restoring.path) else {
        try FileManager.default.removeItem(at: marker)
        throw SnapshotError.restoreMissing(restoring.path)
    }
    let aside = try LibraryIndex.moveAside(databaseURL, reason: "replaced")
    try rename(restoring, to: databaseURL)
    try FileManager.default.removeItem(at: marker)
    logger.notice("restored the library from \(named); the index it replaced is \(aside.path)")
    return named
}

/// `library.sqlite.restoring`: the snapshot unpacked, until the next launch puts it in place.
private func restoringFileURL(_ databaseURL: URL) -> URL {
    URL(fileURLWithPath: databaseURL.path + ".restoring", isDirectory: false)
}

/// The marker a prepared restore leaves beside the index, naming the snapshot.
private func restoreMarkerURL(_ databaseURL: URL) -> URL {
    databaseURL.deletingLastPathComponent().appendingPathComponent(
        "restore.pending", isDirectory: false)
}

/// Throws unless SQLite's integrity check of the database at `url` passes.
private func checkWhole(_ url: URL, name: String) throws {
    let found: [String]
    do {
        found = try Database(readOnlyAt: url).prepare("PRAGMA integrity_check").map {
            try $0.text(0)
        }
    } catch {
        throw SnapshotError.damaged(name, "\(error)")
    }
    guard found == ["ok"] else {
        throw SnapshotError.damaged(name, found.prefix(3).joined(separator: "; "))
    }
}
