import Darwin
import Foundation
import Log
import Metadata
import Settings

private let logger = moduleLogger()

/// Brings the index in line with a watched folder: reads new and changed files, and removes
/// files that are gone. Incremental on (path, size, mtime), so a rescan with no changes reads no
/// file.
///
/// A missing, empty or vanished folder, and any directory that can't be listed, removes nothing
/// under it (ADR 0009). Music files are only ever opened read-only, by `readMetadata`.
public struct LibraryScanner: Sendable {
    /// Files read at once on a local disk, where parsing, not waiting, is the cost.
    static let localReaders = ProcessInfo.processInfo.activeProcessorCount
    /// Files stored per transaction: big enough that commits cost little, small enough that
    /// readers see progress and a cancelled scan keeps most of its work.
    static let batchSize = 500

    public let databaseURL: URL
    /// Files read at once on a network volume, or nil to tune it to the volume as the scan runs.
    public let networkReaders: Int?
    let access: any ScanFileAccess

    public init(
        databaseURL: URL, networkReaders: Int? = nil,
        access: any ScanFileAccess = SystemFileAccess()
    ) {
        precondition(networkReaders.map { $0 > 0 } ?? true, "a scan needs at least one reader")
        self.databaseURL = databaseURL
        self.networkReaders = networkReaders
        self.access = access
    }

    /// Scans `folder`, or only the directories in `subtrees`, each of which must be inside it.
    /// Blocks until done, so call it off the main thread and outside Swift concurrency's
    /// threads. Throws only when the database fails; problems with files and folders are in the
    /// summary.
    public func scan(
        _ folder: WatchedFolder, only subtrees: [String] = [], control: ScanControl = ScanControl(),
        progress: AsyncStream<ScanProgress>.Continuation? = nil
    ) throws -> ScanSummary {
        let root = canonicalPath(folder.path)
        var summary = ScanSummary()
        guard let device = directoryDevice(root) else {
            summary.issues.append(
                ScanIssue(
                    kind: .rootUnavailable, path: root,
                    detail: "missing or not a directory; the index keeps its files"))
            logger.error("\(root) is unavailable; skipping it")
            return summary
        }
        let isLocal: Bool
        do {
            // Nil only where the volume doesn't say; reading as a network volume is the safe
            // guess, since it only means tuning the readers.
            isLocal = try access.volumeIsLocal(root) ?? false
        } catch {
            isLocal = false
            logger.error("can't tell whether \(root) is on a local volume: \(error)")
        }
        if folder.kind == .local, !isLocal {
            summary.issues.append(
                ScanIssue(
                    kind: .networkFolderMarkedLocal, path: root,
                    detail: "on a network volume, where FSEvents reports no changes"))
        }

        let index = try LibraryIndex(at: databaseURL)
        let filter = FolderFilter(include: folder.include, exclude: folder.exclude)
        let starts = subtrees.isEmpty ? [root] : coalesced(subtrees, in: root)
        var known: [String: KnownFile] = [:]
        for start in starts { known.merge(try index.knownFiles(under: start)) { a, _ in a } }

        // Walk and read at once.
        let readers: ScanPipeline.Readers =
            if isLocal {
                .fixed(Self.localReaders)
            } else if let networkReaders {
                .fixed(networkReaders)
            } else {
                .tuned(ReadConcurrency())
            }
        let pipeline = ScanPipeline(
            starts.filter { startIsIncluded($0, root: root, filter: filter) }, root: root,
            filter: filter, known: known, index: index, readers: readers,
            access: access, control: control, counter: ProgressCounter(progress),
            rootIsThere: { directoryDevice(root) == device })
        let outcome = try pipeline.run()
        summary.read = outcome.read
        summary.failed = outcome.failed
        summary.unchanged = outcome.unchanged
        summary.otherFiles = outcome.otherFiles
        summary.issues += outcome.issues
        summary.readers = outcome.readers
        if outcome.cancelled {
            summary.cancelled = true
            return summary
        }
        if outcome.rootLost || directoryDevice(root) != device {
            summary.issues.append(
                ScanIssue(
                    kind: .rootVanished, path: root,
                    detail: "went away during the scan; the index keeps files it didn't see"))
            return summary
        }
        if outcome.rootEntries == 0, !known.isEmpty {
            summary.issues.append(
                ScanIssue(
                    kind: .rootEmpty, path: root,
                    detail: "lists nothing but the index holds \(known.count) files from it;"
                        + " the index keeps them"))
            return summary
        }

        // The walk finished, so remove what's gone, except under anything it couldn't see.
        let protected = summary.issues.filter { $0.kind == .unreadable }.map(\.path)
        let gone = known.filter { path, _ in
            !outcome.seen.contains(path)
                && !protected.contains { $0 == path || isPath(path, under: $0) }
        }
        try index.remove(gone.map(\.value.id))
        summary.removed = gone.count
        try index.deleteOrphans()
        try index.checkpoint()
        logger.info(
            "scanned \(root): \(summary.read) read, \(summary.unchanged) unchanged, \(summary.removed) removed, \(summary.issues.count) issues"
        )
        return summary
    }
}

/// The device of the directory at `path`, or nil when it's missing or not a directory. A NAS
/// unmounted mid-scan leaves its mount point on the startup disk's device, or gone.
private func directoryDevice(_ path: String) -> dev_t? {
    var info = stat()
    guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
    return info.st_dev
}

/// Whether `path` is a directory whose last component is spelled as it is on disk. A volume that
/// ignores case finds a folder renamed only in case under its old name too.
private func isDirectory(spelledAsOnDisk path: String) -> Bool {
    guard directoryDevice(path) != nil, let resolved = realpath(path, nil) else { return false }
    defer { free(resolved) }
    return (String(cString: resolved) as NSString).lastPathComponent
        == (path as NSString).lastPathComponent
}

/// `subtrees` without those inside another, each moved up to its nearest existing directory so
/// a deleted folder's files are found missing. A folder renamed only in case counts as deleted
/// under its old spelling, so its parent is scanned and finds the old-case paths gone. Each must
/// be inside `root`.
private func coalesced(_ subtrees: [String], in root: String) -> [String] {
    var starts: [String] = []
    for subtree in subtrees {
        precondition(
            subtree == root || isPath(subtree, under: root), "\(subtree) isn't inside \(root)")
        var start = subtree
        while start != root, !isDirectory(spelledAsOnDisk: start) {
            start = (start as NSString).deletingLastPathComponent
        }
        starts.append(start)
    }
    let unique = Set(starts)
    return unique.filter { start in !unique.contains { $0 != start && isPath(start, under: $0) } }
        .sorted()
}

/// Progress, published to the stream under a lock so values arrive in order.
final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var progress = ScanProgress()
    private let continuation: AsyncStream<ScanProgress>.Continuation?

    init(_ continuation: AsyncStream<ScanProgress>.Continuation?) {
        self.continuation = continuation
    }

    func update(_ change: (inout ScanProgress) -> Void) {
        lock.withLock {
            change(&progress)
            continuation?.yield(progress)
        }
    }
}
