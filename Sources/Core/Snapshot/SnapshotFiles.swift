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

/// Renames `source` to `destination`, replacing a file there in one step, as `rename(2)` does.
func rename(_ source: URL, to destination: URL) throws(SnapshotError) {
    guard Darwin.rename(source.path, destination.path) == 0 else {
        throw .file(destination.path, String(cString: strerror(errno)))
    }
}
