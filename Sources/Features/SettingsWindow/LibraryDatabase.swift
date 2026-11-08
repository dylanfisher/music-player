import Foundation

/// The library index and its snapshots as the Library section shows them (ADR 0142), which the
/// app reads off the main actor each time the pane shows.
public struct LibraryDatabase: Sendable, Equatable {
    /// One snapshot in the snapshot folder.
    public struct Snapshot: Sendable, Equatable {
        public var path: String
        /// The local day it's of, `YYYY-MM-DD`.
        public var day: String
        public var written: Date
        /// Its size on disk, compressed.
        public var bytes: Int
        /// Whether a restore wrote it, of the index it replaced.
        public var beforeRestore: Bool

        public init(path: String, day: String, written: Date, bytes: Int, beforeRestore: Bool) {
            self.path = path
            self.day = day
            self.written = written
            self.bytes = bytes
            self.beforeRestore = beforeRestore
        }

        /// The list's Taken column.
        var takenText: String {
            LibraryDatabase.writtenText(written) + (beforeRestore ? " (before a restore)" : "")
        }
    }

    public var indexPath: String
    /// The index file and its write-ahead log.
    public var indexBytes: Int
    /// Newest first.
    public var snapshots: [Snapshot]
    /// Why the last snapshot failed, while the app has run, or nil.
    public var lastFailure: String?

    public init(indexPath: String, indexBytes: Int, snapshots: [Snapshot], lastFailure: String?) {
        self.indexPath = indexPath
        self.indexBytes = indexBytes
        self.snapshots = snapshots
        self.lastFailure = lastFailure
    }

    /// The index's path with the home folder as `~`.
    var pathText: String { (indexPath as NSString).abbreviatingWithTildeInPath }

    var sizeText: String { Self.bytesText(indexBytes) }

    /// The Last Snapshot row: why the last one failed, else when the newest was written.
    var lastSnapshotText: String {
        if let lastFailure { return "Last snapshot failed: \(lastFailure)" }
        guard let newest = snapshots.first else { return "None yet" }
        return Self.writtenText(newest.written)
    }

    static func bytesText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func writtenText(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }
}
