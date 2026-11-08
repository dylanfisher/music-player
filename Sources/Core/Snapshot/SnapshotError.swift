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

    public var description: String {
        switch self {
        case .file(let path, let detail): "\(path): \(detail)"
        case .gzip(let name, let detail): "\(name) isn't a whole gzip file: \(detail)"
        case .damaged(let name, let detail):
            "\(name) holds a damaged library, so it can't be restored: \(detail)"
        case .restoreMissing(let path):
            "the snapshot to restore was to be at \(path), but it's gone; the library is as it was"
        }
    }
}
