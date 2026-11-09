import Foundation
import Library
import Log
import Settings

private let logger = moduleLogger()

/// Held through each snapshot write, so two never run at once: the daily job, Back Up Now
/// and a restore's snapshot can come from different queues.
private let writing = NSLock()
/// How old a write's file has to be before another write takes it for one stopped partway,
/// rather than a write of another copy of the app still under way.
private let leftoverSeconds = 3600.0

/// A snapshot in the snapshot folder, as Settings lists it.
public struct SnapshotFile: Equatable, Sendable {
    let name: SnapshotName
    public let url: URL
    /// Its size on disk, compressed.
    public let bytes: Int
    /// When it was written, from the file.
    public let written: Date

    /// The local day it's of, `YYYY-MM-DD`.
    public var day: String { name.day }
    /// Whether a restore wrote it, of the index it replaced.
    public var isBeforeRestore: Bool { name.beforeRestoreTime != nil }
}

/// Writes the index as `library-YYYY-MM-DD.sqlite.gz` in `folder`, for the local day `date`
/// falls on, replacing that day's snapshot if there is one, or with `beforeRestore` under a
/// name of its own for that second, then deletes the snapshots rotation
/// no longer keeps, and returns where it wrote (ADR 0142). The index is copied with
/// `VACUUM INTO`, a read, which leaves it as it was; the copy is compressed beside the
/// snapshot, then renamed over it, so the folder never holds a snapshot cut short under a
/// snapshot's name. Beside it go copies of the state and config files in `paths`, the config
/// file's without its secrets, each written whole before any is renamed into place (ADR 0181).
/// When only the rotation fails, it throws `SnapshotError.notRotated`, with the snapshot
/// written.
@discardableResult
func writeSnapshot(
    of index: LibraryIndex, keeping paths: AppPaths, into folder: URL, on date: Date,
    beforeRestore: Bool = false, calendar: Calendar = .current
) throws -> URL {
    try writing.withLock {
        let name = SnapshotName(of: date, beforeRestore: beforeRestore, calendar: calendar)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try requireLocal(
            folder, isLocal: try folder.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal)
        try removePartials(in: folder, olderThan: Date().addingTimeInterval(-leftoverSeconds))
        let token = UUID().uuidString
        let copy = folder.appendingPathComponent(name.copyFileName(token), isDirectory: false)
        let packed = folder.appendingPathComponent(
            name.partialFileName(token), isDirectory: false)
        let snapshot = folder.appendingPathComponent(name.fileName, isDirectory: false)
        defer { removeLeftover(copy) }
        try index.copy(to: copy)
        var partials = [packed]
        do {
            try GzipFile.compress(copy, to: packed)
            var parts: [(kept: URL, partial: URL?)] = []
            for part in SnapshotPart.allCases {
                let kept = folder.appendingPathComponent(
                    name.fileName(of: part), isDirectory: false)
                guard let data = try keptCopy(of: part, at: part.liveFile(paths)) else {
                    parts.append((kept, nil))
                    continue
                }
                let partial = folder.appendingPathComponent(
                    name.partialFileName(token, of: part), isDirectory: false)
                partials.append(partial)
                try writePrivate(data, to: partial)
                parts.append((kept, partial))
            }
            // The index's first, so a copy is never there without the snapshot it's of.
            try rename(packed, to: snapshot)
            for (kept, partial) in parts {
                // A file with no copy now keeps none from an earlier snapshot of the day.
                if let partial { try rename(partial, to: kept) } else { try removeIfThere(kept) }
            }
        } catch {
            partials.forEach(removeLeftover)
            throw error
        }
        do {
            try rotateSnapshots(in: folder, calendar: calendar)
        } catch {
            throw SnapshotError.notRotated("\(error)")
        }
        return snapshot
    }
}

/// What a snapshot keeps of `part`'s file at `url`: the state file as it is, the config file
/// without its secrets. Nil when there's no file, and for a config file that isn't a JSON
/// object, which is logged: its secrets can't be told from the rest, so none of it is copied.
private func keptCopy(of part: SnapshotPart, at url: URL) throws -> Data? {
    guard let data = try readIfThere(url) else { return nil }
    switch part {
    case .state: return data
    case .config:
        do {
            return Data(
                try ConfigSecrets.removed(from: String(decoding: data, as: UTF8.self)).utf8)
        } catch {
            logger.error("the snapshot keeps no copy of \(url.path), which doesn't read: \(error)")
            return nil
        }
    }
}

/// The snapshots in `folder`, the newest written first, and none while there is no folder.
/// Other files there are left out, and so is a snapshot whose size or date can't be read,
/// which is logged.
public func snapshots(in folder: URL) throws -> [SnapshotFile] {
    let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
    let urls: [URL]
    do {
        urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys)
    } catch CocoaError.fileReadNoSuchFile {
        return []
    }
    return urls.compactMap { url in
        guard let name = SnapshotName(fileName: url.lastPathComponent) else { return nil }
        do {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard let bytes = values.fileSize, let written = values.contentModificationDate
            else { throw SnapshotError.file(url.path, "its size or date can't be read") }
            return SnapshotFile(name: name, url: url, bytes: bytes, written: written)
        } catch {
            logger.error("leaving out the snapshot \(url.path): \(error)")
            return nil
        }
    }
    .sorted { ($0.written, $0.name) > ($1.written, $1.name) }
}

/// Deletes the snapshots in `folder` that rotation no longer keeps, with their copies of the
/// state and config files, and only those: nothing else in the folder is touched.
private func rotateSnapshots(in folder: URL, calendar: Calendar) throws {
    let found = try snapshots(in: folder)
    let expired = Set(SnapshotRotation.expired(found.map(\.name), calendar: calendar))
    for snapshot in found where expired.contains(snapshot.name) {
        // The copies first, so a delete that fails leaves none without its snapshot.
        for part in SnapshotPart.allCases {
            try removeIfThere(
                folder.appendingPathComponent(snapshot.name.fileName(of: part), isDirectory: false))
        }
        try FileManager.default.removeItem(at: snapshot.url)
    }
}

/// Throws unless `folder` is on a local volume, as `isLocal` says (ADR 0142): a folder on a
/// network volume, a watched share's among them, is refused when the snapshot is written,
/// since Settings can't tell where a share is mounted.
func requireLocal(_ folder: URL, isLocal: Bool?) throws(SnapshotError) {
    guard isLocal == true else { throw .networkFolder(folder.path) }
}

/// Deletes the files in `folder` that writes stopped partway left, last changed before
/// `cutoff`.
func removePartials(in folder: URL, olderThan cutoff: Date) throws {
    for name in try FileManager.default.contentsOfDirectory(atPath: folder.path)
    where SnapshotName.isPartial(name) {
        let url = folder.appendingPathComponent(name, isDirectory: false)
        guard let changed = try modificationDate(url), changed < cutoff else { continue }
        try removeIfThere(url)
    }
}

/// When the file at `url` last changed, or nil when it's gone, as another copy's write
/// deletes its own between a listing and this read.
func modificationDate(_ url: URL) throws -> Date? {
    do {
        return try url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
        return nil
    }
}

/// Deletes the writer's own file at `url`, logging a failure, which leaves a file the next
/// write deletes.
private func removeLeftover(_ url: URL) {
    do {
        try removeIfThere(url)
    } catch {
        logger.error("couldn't delete \(url.path): \(error)")
    }
}
