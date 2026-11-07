/// Why an import failed. The old catalog, if any, is still in use after every one of them.
public enum CatalogImportError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The folder has no date with all four dumps and a checksum file listing them.
    case noDumpSet(folder: String, found: [String])
    case unreadable(String, String)
    /// The new catalog couldn't be written, as on a full disk.
    case unwritable(String, String)
    /// The checksum file has a line that isn't a SHA-256 and a file name.
    case badChecksumFile(String, line: Int)
    case checksumMismatch(String, expected: String, actual: String)
    /// The file ends before its gzip trailer: a download cut short.
    case truncated(String)
    case corrupt(String, String)
    /// The inflated XML isn't a dump this import can read.
    case malformed(String, line: Int, String)
    /// The catalog's path is inside a watched folder, where only music files belong.
    case catalogInsideWatchedFolder(catalog: String, folder: String)
    /// The dumps folder is on a share that isn't mounted.
    case shareNotMounted(String)
    /// The dumps folder's share has its name mounted from several hosts.
    case shareAmbiguous(String, mountPoints: [String])
    /// Stopped by the caller.
    case stopped

    public var description: String {
        switch self {
        case .noDumpSet(let folder, let found):
            "\(folder) has no complete Discogs dump: the releases, masters, artists and labels"
                + " files of one date and its CHECKSUM.txt listing them"
                + (found.isEmpty ? "" : " (found \(found.joined(separator: ", ")))")
        case .unreadable(let file, let reason): "\(file) couldn't be read: \(reason)"
        case .unwritable(let file, let reason): "the catalog \(file) couldn't be written: \(reason)"
        case .badChecksumFile(let file, let line):
            "\(file) line \(line) isn't a SHA-256 and a file name"
        case .checksumMismatch(let file, let expected, let actual):
            "\(file) doesn't match its checksum: expected \(expected), read \(actual)"
        case .truncated(let file): "\(file) ends before its gzip data does: it was cut short"
        case .corrupt(let file, let reason): "\(file) isn't readable gzip data: \(reason)"
        case .malformed(let file, let line, let reason):
            "\(file) line \(line) isn't a Discogs dump this app can read: \(reason)"
        case .catalogInsideWatchedFolder(let catalog, let folder):
            "the catalog \(catalog) is inside the watched folder \(folder); it must be outside"
                + " every watched folder"
        case .shareNotMounted(let share):
            "the dumps folder's share \(share) isn't mounted; connect to it and try again"
        case .shareAmbiguous(let share, let mountPoints):
            "the dumps folder's share \(share) could be any of"
                + " \(mountPoints.joined(separator: ", ")); eject the others and try again"
        case .stopped: "the import was stopped"
        }
    }
}
