import Foundation
import Library
import Log

private let logger = moduleLogger()

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
}

/// Writes the index as `library-YYYY-MM-DD.sqlite.gz` in `folder`, for the local day `date`
/// falls on, replacing that day's snapshot if there is one, then deletes the snapshots rotation
/// no longer keeps, and returns where it wrote (ADR 0142). The index is copied with
/// `VACUUM INTO`, a read, which leaves it as it was; the copy is compressed beside the
/// snapshot, then renamed over it, so the folder never holds a snapshot cut short under a
/// snapshot's name.
@discardableResult
func writeSnapshot(
    of index: LibraryIndex, into folder: URL, on date: Date, calendar: Calendar = .current
) throws -> URL {
    let name = SnapshotName(of: date, calendar: calendar)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try removePartials(in: folder)
    let copy = folder.appendingPathComponent(name.copyFileName, isDirectory: false)
    let packed = folder.appendingPathComponent(name.partialFileName, isDirectory: false)
    let snapshot = folder.appendingPathComponent(name.fileName, isDirectory: false)
    defer { removeLeftover(copy) }
    try index.copy(to: copy)
    do {
        try GzipFile.compress(copy, to: packed)
        try rename(packed, to: snapshot)
    } catch {
        removeLeftover(packed)
        throw error
    }
    try rotateSnapshots(in: folder, calendar: calendar)
    return snapshot
}

/// The snapshots in `folder`, newest first, and none while there is no folder. Other files
/// there are left out.
public func snapshots(in folder: URL) throws -> [SnapshotFile] {
    let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
    let urls: [URL]
    do {
        urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys)
    } catch CocoaError.fileReadNoSuchFile {
        return []
    }
    return try urls.compactMap { url in
        guard let name = SnapshotName(fileName: url.lastPathComponent) else { return nil }
        let values = try url.resourceValues(forKeys: Set(keys))
        guard let bytes = values.fileSize, let written = values.contentModificationDate else {
            throw SnapshotError.file(url.path, "its size or date can't be read")
        }
        return SnapshotFile(name: name, url: url, bytes: bytes, written: written)
    }
    .sorted { $0.name > $1.name }
}

/// Deletes the snapshots in `folder` that rotation no longer keeps, and only those: nothing
/// else in the folder is touched.
private func rotateSnapshots(in folder: URL, calendar: Calendar) throws {
    let found = try snapshots(in: folder)
    let expired = Set(SnapshotRotation.expired(found.map(\.name), calendar: calendar))
    for snapshot in found where expired.contains(snapshot.name) {
        try FileManager.default.removeItem(at: snapshot.url)
    }
}

/// Deletes what a write stopped partway left in `folder`.
private func removePartials(in folder: URL) throws {
    for name in try FileManager.default.contentsOfDirectory(atPath: folder.path)
    where SnapshotName.isPartial(name) {
        try FileManager.default.removeItem(
            at: folder.appendingPathComponent(name, isDirectory: false))
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
