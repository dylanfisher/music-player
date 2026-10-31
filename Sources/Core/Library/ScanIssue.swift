/// A problem with a watched folder or one of its directories, as opposed to one file's tags.
/// Every kind but `symbolicLink` and `networkFolderMarkedLocal` stops the scan removing
/// anything at or under `path`, so a missing volume never reads as deleted files.
public struct ScanIssue: Equatable, Sendable, CustomStringConvertible {
    public enum Kind: String, CaseIterable, Sendable {
        /// The folder doesn't exist or isn't a directory, as when a NAS isn't mounted.
        case rootUnavailable
        /// The folder lists nothing though the index holds files from it: most likely an empty
        /// mount point.
        case rootEmpty
        /// The folder went away or moved to another volume during the scan.
        case rootVanished
        /// A directory or entry that couldn't be listed or stat'ed.
        case unreadable
        /// Not followed, so a link can't loop or reach outside the folder.
        case symbolicLink
        /// FSEvents doesn't report changes on network volumes, so this folder needs `network`.
        case networkFolderMarkedLocal
    }

    public var kind: Kind
    public var path: String
    public var detail: String

    public var description: String { "\(path): \(kind.rawValue): \(detail)" }
}
