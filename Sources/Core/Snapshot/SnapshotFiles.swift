import Darwin
import Foundation

/// Deletes the file at `url`, if there is one.
func removeIfThere(_ url: URL) throws {
    do {
        try FileManager.default.removeItem(at: url)
    } catch CocoaError.fileNoSuchFile {
        return
    }
}

/// The file at `url`, or nil when there's none.
func readIfThere(_ url: URL) throws -> Data? {
    do {
        return try Data(contentsOf: url)
    } catch CocoaError.fileReadNoSuchFile {
        return nil
    }
}

/// Renames `source` to `destination`, replacing a file there in one step, as `rename(2)` does.
func rename(_ source: URL, to destination: URL) throws(SnapshotError) {
    guard Darwin.rename(source.path, destination.path) == 0 else {
        throw .file(destination.path, String(cString: strerror(errno)))
    }
}

/// Writes `data` to a new file at `url` only its owner can read or write, synced, since a copy
/// of the config file is as private as the file (ADR 0137).
func writePrivate(_ data: Data, to url: URL) throws(SnapshotError) {
    // `open`'s mode passes through the umask, which only takes bits away.
    let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw .file(url.path, String(cString: strerror(errno))) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
        try handle.write(contentsOf: data)
        try handle.synchronize()
    } catch {
        throw .file(url.path, error.localizedDescription)
    }
}

/// Writes `data` over the file at `url` as `writePrivate` does, by a file beside it renamed
/// over it, so a reader finds the old file or the new one, never part of one.
func replacePrivate(_ data: Data, at url: URL) throws {
    let partial = URL(fileURLWithPath: url.path + SnapshotName.partialSuffix, isDirectory: false)
    try removeIfThere(partial)
    try writePrivate(data, to: partial)
    try rename(partial, to: url)
}
