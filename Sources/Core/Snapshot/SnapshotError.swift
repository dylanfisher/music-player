/// Why a snapshot couldn't be written, read or restored (ADR 0142).
public enum SnapshotError: Error, Equatable, CustomStringConvertible {
    /// A file couldn't be opened, read or written: its path and why.
    case file(String, String)
    /// A gzip file's name and what is wrong with its data.
    case gzip(String, String)
    /// A snapshot that unpacks to a database SQLite finds damaged: its name and what SQLite says.
    case damaged(String, String)
    /// A restore was asked for at launch, and the unpacked snapshot it would put in place is
    /// gone: its path.
    case restoreMissing(String)
    /// A restore at launch moved the index aside to this path and could neither put the
    /// snapshot in its place nor move it back: why.
    case indexNotPutBack(String, String)
    /// The snapshot folder, at this path, is on a network volume, which isn't written.
    case networkFolder(String)
    /// The snapshot was written, but older ones rotation deletes couldn't be: why.
    case notRotated(String)

    public var description: String {
        switch self {
        case .file(let path, let detail): "\(path): \(detail)"
        case .gzip(let name, let detail): "\(name) isn't a whole gzip file: \(detail)"
        case .damaged(let name, let detail):
            "\(name) holds a damaged library, so it can't be restored: \(detail)"
        case .restoreMissing(let path):
            "the snapshot to restore was to be at \(path), but it's gone; the library is as it was"
        case .networkFolder(let path):
            "the snapshot folder \(path) is on a network volume; choose a folder on this Mac,"
                + " which a restore needs too, since it snapshots the library first"
        case .notRotated(let detail):
            "the snapshot was written, but older ones couldn't be deleted: \(detail)"
        case .indexNotPutBack(let path, let detail):
            "the library was moved to \(path) for a restore, which failed, and it couldn't be"
                + " moved back (\(detail)); move it back to library.sqlite before opening the app"
        }
    }
}
