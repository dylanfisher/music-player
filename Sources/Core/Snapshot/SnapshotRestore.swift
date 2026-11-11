import Darwin
import Foundation
import Library
import Log
import SQLite
import Settings

private let logger = moduleLogger()

/// Restore…: unpacks `snapshot` beside the index in `paths`, checks that SQLite reads it
/// whole, copies the snapshot's state and config files beside theirs, snapshots the current
/// index and files into `snapshotFolder`, and leaves a marker naming the snapshot, so the next
/// launch puts them all in place before any is read (ADR 0142, 0181). A snapshot that doesn't
/// unpack, or unpacks damaged, or a config file whose secrets can't be kept, throws with
/// nothing replaced. The current index's snapshot has a name of its own, so it never replaces
/// the day's, which may be the one chosen. The snapshot must be in a folder on a local volume,
/// as the snapshot folder must, and it and its copies regular files with one name each; it
/// may unpack to 4 GiB at most (ADR 0025, row 74).
public func prepareRestore(
    of snapshot: URL, paths: AppPaths, snapshotFolder: URL, now: Date
) throws {
    try prepareRestore(
        of: snapshot, paths: paths, snapshotFolder: snapshotFolder, now: now,
        isLocal: { try $0.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal },
        unpackLimit: GzipFile.maxUnpackedBytes)
}

/// `prepareRestore(of:paths:snapshotFolder:now:)` with `isLocal` saying whether a folder is on
/// a local volume, and `unpackLimit` the most bytes the snapshot may unpack to, which tests
/// set.
func prepareRestore(
    of snapshot: URL, paths: AppPaths, snapshotFolder: URL, now: Date,
    isLocal: (URL) throws -> Bool?, unpackLimit: Int
) throws {
    let databaseURL = libraryFileURL(in: paths.dataDirectory)
    let restoring = restoringFileURL(databaseURL)
    guard let name = SnapshotName(fileName: snapshot.lastPathComponent) else {
        throw SnapshotError.file(snapshot.path, "it isn't named as a snapshot is")
    }
    let folder = snapshot.deletingLastPathComponent()
    try requireLocal(folder, isLocal: try isLocal(folder))
    guard try isRegularFile(snapshot) else {
        throw SnapshotError.file(snapshot.path, "it isn't there")
    }
    // An earlier restore's marker goes first: left beside no unpacked file, it would read as
    // a restore made at the next launch. Its copies go too, so a snapshot without one
    // doesn't restore another's.
    try removeIfThere(restoreMarkerURL(databaseURL))
    for suffix in ["", Database.walSuffix, Database.shmSuffix] {
        try removeIfThere(URL(fileURLWithPath: restoring.path + suffix, isDirectory: false))
    }
    func removeRestoring() throws {
        try removeIfThere(restoring)
        try removeRestoringCopies(paths)
    }
    try removeRestoringCopies(paths)
    do {
        try GzipFile.decompress(snapshot, to: restoring, limit: unpackLimit)
        try checkWhole(restoring, name: snapshot.lastPathComponent)
        for part in SnapshotPart.allCases {
            let kept = folder.appendingPathComponent(name.fileName(of: part), isDirectory: false)
            guard try isRegularFile(kept), let data = try readIfThere(kept) else { continue }
            // Here as well as at launch, so a config file that can't keep its secrets stops
            // the restore before the app quits for it.
            if part == .config { _ = try keepingSecrets(data, of: paths.configFile) }
            try replacePrivate(data, at: restoringFileURL(part.liveFile(paths)))
        }
    } catch {
        try removeRestoring()
        throw error
    }
    do {
        try writeSnapshot(
            of: LibraryIndex(at: databaseURL), keeping: paths, into: snapshotFolder, on: now,
            beforeRestore: true)
    } catch SnapshotError.notRotated(let detail) {
        logger.error("snapshotted the index before the restore, but \(detail)")
    } catch {
        try removeRestoring()
        throw error
    }
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

/// At launch, before the index opens and the state and config files are read: when a restore
/// was prepared, moves the index aside, as `library.sqlite.replaced-<stamp>`, and the
/// unpacked snapshot into its place, then the snapshot's state and config files over theirs,
/// the config file's with the secrets the live one has (ADR 0142, 0181). It waits while
/// another copy of the app holds the index (`IndexInUse`). A config file whose secrets can't
/// be kept throws before anything moves, and the restore waits. When the index's move into
/// place fails, the index goes back and the restore waits, throwing why; when it can't go
/// back, `SnapshotError.indexNotPutBack` says where it is, and nothing should open an index.
/// When a file's move fails after the index's, the restore waits too, and the next launch
/// moves the files left. The replaced indexes are pruned only once the restore is in place,
/// so a failed one never prunes the index it moved.
public func applyPendingRestore(paths: AppPaths) throws -> PendingRestore {
    try applyPendingRestore(paths: paths, move: LibraryIndex.move)
}

/// `applyPendingRestore(paths:)` moving the index with `move`, which tests fail.
func applyPendingRestore(
    paths: AppPaths, move: (URL, URL) throws -> Void
) throws -> PendingRestore {
    let databaseURL = libraryFileURL(in: paths.dataDirectory)
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
    // Before anything moves, so a config file that can't keep its secrets leaves all as it was.
    let config = restoringFileURL(paths.configFile)
    if let restored = try readIfThere(config) {
        try replacePrivate(try keepingSecrets(restored, of: paths.configFile), at: config)
    }
    let restoring = restoringFileURL(databaseURL)
    let index = FileManager.default.fileExists(atPath: databaseURL.path)
    guard FileManager.default.fileExists(atPath: restoring.path) else {
        // Only the move into place takes the unpacked file away: the launch that moved it
        // stopped before it moved the files or deleted the marker.
        guard index else {
            try FileManager.default.removeItem(at: marker)
            try removeRestoringCopies(paths)
            throw SnapshotError.restoreMissing(restoring.path)
        }
        try moveRestoringCopies(paths)
        try FileManager.default.removeItem(at: marker)
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
    try moveRestoringCopies(paths)
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

/// `library.sqlite.restoring`, `state.json.restoring` and `config.json.restoring` beside the
/// file at `url`: the snapshot's, until the next launch puts it in place.
private func restoringFileURL(_ url: URL) -> URL {
    URL(fileURLWithPath: url.path + ".restoring", isDirectory: false)
}

/// Deletes the snapshot's state and config files a restore copied beside theirs.
private func removeRestoringCopies(_ paths: AppPaths) throws {
    for part in SnapshotPart.allCases {
        try removeIfThere(restoringFileURL(part.liveFile(paths)))
    }
}

/// Renames each of the snapshot's state and config files a restore copied over the app's own.
/// Each one left is moved, so a launch stopped partway finishes at the next.
private func moveRestoringCopies(_ paths: AppPaths) throws {
    for part in SnapshotPart.allCases {
        let restoring = restoringFileURL(part.liveFile(paths))
        guard FileManager.default.fileExists(atPath: restoring.path) else { continue }
        try rename(restoring, to: part.liveFile(paths))
        logger.notice("restored \(part.liveFile(paths).path) from the snapshot")
    }
}

/// `restored`, a snapshot's copy of the config file, with the secrets the config file at
/// `live` sets now, and only those (ADR 0181).
private func keepingSecrets(_ restored: Data, of live: URL) throws -> Data {
    let current = try readIfThere(live)
    do {
        return Data(
            try ConfigSecrets.kept(
                from: current.map { String(decoding: $0, as: UTF8.self) },
                in: String(decoding: restored, as: UTF8.self)
            ).utf8)
    } catch {
        throw SnapshotError.configNotKept(live.path, "\(error)")
    }
}

/// The marker a prepared restore leaves beside the index, naming the snapshot.
private func restoreMarkerURL(_ databaseURL: URL) -> URL {
    databaseURL.deletingLastPathComponent().appendingPathComponent(
        "restore.pending", isDirectory: false)
}

/// Whether a file is at `url`, as `lstat` says, without following a link. Throws for anything
/// there but a regular file with one name: a link, a folder, a device or a hard link could
/// make a restore read a file other than the snapshot's.
private func isRegularFile(_ url: URL) throws(SnapshotError) -> Bool {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
        if errno == ENOENT { return false }
        throw .file(url.path, String(cString: strerror(errno)))
    }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
        throw .file(url.path, "it isn't a regular file with one name, so it isn't restored")
    }
    return true
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
