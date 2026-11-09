/// A problem with a watched folder or one of its directories, as opposed to one file's tags.
/// Every kind but `symbolicLink`, `networkFolderMarkedLocal` and `stagingFolderSkipped` stops
/// the scan removing anything at or under `path`, so a missing volume never reads as deleted
/// files.
public struct ScanIssue: Equatable, Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable {
        /// The folder doesn't exist or isn't a directory, as when a NAS isn't mounted.
        case rootUnavailable
        /// The folder lists nothing though the index holds files from it: most likely an empty
        /// mount point.
        case rootEmpty
        /// The folder went away or moved to another volume during the scan.
        case rootVanished
        /// The walk was given a file more than once, so its listings can't be trusted to say
        /// what's gone (ADR 0151).
        case listedTwice
        /// A directory or entry that couldn't be listed or stat'ed.
        case unreadable
        /// Not followed, so a link can't loop or reach outside the folder.
        case symbolicLink
        /// FSEvents doesn't report changes on network volumes, so this folder needs `network`.
        case networkFolderMarkedLocal
        /// The staging folder is inside the watched folder, where the scan passes over it.
        case stagingFolderSkipped
        /// The watched folder is in the staging folder, so it isn't scanned.
        case insideStagingFolder
    }

    public var kind: Kind
    public var path: String
    public var detail: String

    public var description: String { "\(path): \(kind.rawValue): \(detail)" }
}
