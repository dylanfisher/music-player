import Darwin
import Foundation
import Library
import Log
import SQLite

private let logger = moduleLogger()

/// Restore…: unpacks `snapshot` beside the index at `databaseURL`, checks that SQLite reads
/// it whole, snapshots the current index into `snapshotFolder`, and leaves a marker naming the
/// snapshot, so the next launch puts the unpacked file in the index's place before it opens
/// (ADR 0142). A snapshot that doesn't unpack, or unpacks damaged, throws with nothing
/// replaced. The current index's snapshot has a name of its own, so it never replaces the
/// day's, which may be the one chosen.
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
    try writeSnapshot(
        of: LibraryIndex(at: databaseURL), into: snapshotFolder, on: now, beforeRestore: true)
    try Data((snapshot.lastPathComponent + "\n").utf8).write(
        to: restoreMarkerURL(databaseURL), options: .atomic)
}

/// What a launch's look for a prepared restore found.
public enum PendingRestore: Equatable, Sendable {
    case none
    /// The snapshot, by its file's name, is the index now.
    case applied(String)
    /// The restore waits for the next launch, for this reason.
    case waiting(String)
}

/// The moved-aside index's reason, as `library.sqlite.replaced-<stamp>`.
private let replacedReason = "replaced"

/// At launch, before the index opens: when a restore was prepared, moves the index aside, as
/// `library.sqlite.replaced-<stamp>`, and the unpacked snapshot into its place (ADR 0142). It
/// waits while another copy of the app holds the index (`IndexInUse`). When the move into
/// place fails, the index goes back and the restore waits, throwing why; when it can't go
/// back, `SnapshotError.indexNotPutBack` says where it is, and nothing should open an index.
/// The replaced indexes are pruned only once the restore is in place, so a failed one never
/// prunes the index it moved.
public func applyPendingRestore(databaseURL: URL) throws -> PendingRestore {
    try applyPendingRestore(databaseURL: databaseURL, move: LibraryIndex.move)
}

/// `applyPendingRestore(databaseURL:)` moving files with `move`, which tests fail.
func applyPendingRestore(
    databaseURL: URL, move: (URL, URL) throws -> Void
) throws -> PendingRestore {
    let marker = restoreMarkerURL(databaseURL)
    let named: String
    do {
        named = try String(contentsOf: marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch CocoaError.fileReadNoSuchFile {
        return .none
    }
    guard let swapping = try IndexInUse.exclusive(databaseURL) else {
        return .waiting("another copy of the app has the library open")
    }
    defer { withExtendedLifetime(swapping) {} }
    let restoring = restoringFileURL(databaseURL)
    let index = FileManager.default.fileExists(atPath: databaseURL.path)
    guard FileManager.default.fileExists(atPath: restoring.path) else {
        try FileManager.default.removeItem(at: marker)
        // Only the move into place takes the unpacked file away: the launch that moved it
        // stopped before it deleted the marker.
        guard index else { throw SnapshotError.restoreMissing(restoring.path) }
        return .applied(named)
    }
    let aside =
        index
        ? try LibraryIndex.moveAside(databaseURL, reason: replacedReason, pruning: false) : nil
    do {
        try move(restoring, databaseURL)
    } catch {
        guard let aside else { throw error }
        do {
            try move(aside, databaseURL)
        } catch let putBack {
            throw SnapshotError.indexNotPutBack(aside.path, "\(error); then \(putBack)")
        }
        throw error
    }
    try FileManager.default.removeItem(at: marker)
    logger.notice(
        "restored the library from \(named), moving the index it replaced to \(aside?.path ?? "nowhere, as there was none")"
    )
    do {
        try LibraryIndex.pruneMovedAside(databaseURL, reason: replacedReason)
    } catch {
        logger.error("couldn't delete the older indexes restores replaced: \(error)")
    }
    return .applied(named)
}

/// A lock on `library.sqlite.in-use` beside the index, held shared by each copy of the app
/// for as long as it runs and exclusive by a restore's swap at launch, so the swap never
/// replaces an index another copy has open (ADR 0142). It's released when this is freed.
public final class IndexInUse {
    private let descriptor: Int32

    /// Waits for a swap under way, then holds the lock shared.
    public convenience init(databaseURL: URL) throws {
        guard let descriptor = try Self.lock(databaseURL, LOCK_SH) else {
            preconditionFailure("a lock that waits returned without it")
        }
        self.init(descriptor: descriptor)
    }

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit { Darwin.close(descriptor) }

    /// The lock exclusive, without waiting: nil while another holds it.
    static func exclusive(_ databaseURL: URL) throws -> IndexInUse? {
        try lock(databaseURL, LOCK_EX | LOCK_NB).map { IndexInUse(descriptor: $0) }
    }

    /// The lock file's descriptor holding `operation`, or nil when it would wait.
    private static func lock(_ databaseURL: URL, _ operation: Int32) throws -> Int32? {
        let path = databaseURL.path + ".in-use"
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw SnapshotError.file(path, String(cString: strerror(errno)))
        }
        guard flock(descriptor, operation) == 0 else {
            let reason = errno
            Darwin.close(descriptor)
            if reason == EWOULDBLOCK { return nil }
            throw SnapshotError.file(path, String(cString: strerror(reason)))
        }
        return descriptor
    }
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
