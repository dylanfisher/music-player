import DisplayText
import Foundation

/// The library index and its snapshots as the Database section shows them (ADR 0142), which the
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
    /// What went wrong with the last snapshot, while the app has run, in a sentence, or nil.
    public var lastProblem: String?

    public init(indexPath: String, indexBytes: Int, snapshots: [Snapshot], lastProblem: String?) {
        self.indexPath = indexPath
        self.indexBytes = indexBytes
        self.snapshots = snapshots
        self.lastProblem = lastProblem
    }

    /// The index's path with the home folder as `~`.
    var pathText: String { (indexPath as NSString).abbreviatingWithTildeInPath }

    var sizeText: String { fileSizeText(indexBytes) }

    /// The Last Snapshot row: what went wrong with the last one, else when the newest was
    /// written.
    var lastSnapshotText: String {
        if let lastProblem { return lastProblem }
        guard let newest = snapshots.first else { return "None yet" }
        return Self.writtenText(newest.written)
    }

    static func writtenText(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }
}
