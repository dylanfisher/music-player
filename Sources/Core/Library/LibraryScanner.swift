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
    static let defaultBatchSize = 500

    public let databaseURL: URL
    /// Files read at once on a network volume, or nil to tune it to the volume as the scan runs.
    public let networkReaders: Int?
    let access: any ScanFileAccess
    let batchSize: Int

    public init(
        databaseURL: URL, networkReaders: Int? = nil,
        access: any ScanFileAccess = SystemFileAccess()
    ) {
        self.init(
            databaseURL: databaseURL, networkReaders: networkReaders, access: access,
            batchSize: Self.defaultBatchSize)
    }

    /// For tests, which store a small library in several batches. A batch size under 1 stores
    /// each file on its own.
    init(
        databaseURL: URL, networkReaders: Int? = nil, access: any ScanFileAccess, batchSize: Int
    ) {
        self.databaseURL = databaseURL
        self.networkReaders = networkReaders
        self.access = access
        self.batchSize = batchSize
    }

    /// Scans `folder`, or only the directories in `subtrees`, each of which must be inside it,
    /// reading and removing as `options` say. Blocks until done, so call it off the main thread
    /// and outside Swift concurrency's threads. Throws only when the database fails; problems
    /// with files and folders are in the summary.
    public func scan(
        _ folder: WatchedFolder, only subtrees: [String] = [], control: ScanControl = ScanControl(),
        progress: AsyncStream<ScanProgress>.Continuation? = nil,
        options: ScanOptions = ScanOptions()
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

        let skipped = options.skippedFolders.map(canonicalPath)
        if let staging = skipped.first(where: { isPath(root, inOrAt: $0) }) {
            summary.issues.append(
                ScanIssue(
                    kind: .insideStagingFolder, path: root,
                    detail: "is in the staging folder \(staging), which no scan reads;"
                        + " move it out, or watch another folder"))
            logger.error("\(root) is in the staging folder \(staging); not scanning it")
            return summary
        }
        let skippedInside = skipped.filter { isPath($0, under: root) }
        for staging in skippedInside {
            summary.issues.append(
                ScanIssue(
                    kind: .stagingFolderSkipped, path: staging,
                    detail: "the staging folder is inside the watched folder; its downloads"
                        + " aren't read"))
        }

        let index = try LibraryIndex(at: databaseURL)
        // About 64 MB of log, which the checkpoint at the end of a finished scan truncates.
        try index.setAutoCheckpointPages(16384)
        let started = Date()
        if subtrees.isEmpty { try index.setFinishedWholeScan(of: root, startedAt: nil) }
        let filter = FolderFilter(include: folder.include, exclude: folder.exclude)
        let starts = subtrees.isEmpty ? [root] : coalesced(subtrees, in: root)
        var known: [String: KnownFile] = [:]
        for start in starts { known.merge(try index.knownFiles(under: start)) { a, _ in a } }

        // Walk and read at once.
        let controller: ReadConcurrency?
        let readers: Int
        if isLocal {
            (controller, readers) = (nil, Self.localReaders)
        } else if let networkReaders {
            (controller, readers) = (nil, networkReaders)
        } else {
            let tuning = ReadConcurrency()
            (controller, readers) = (tuning, tuning.level)
        }
        let pipeline = ScanPipeline(
            starts.filter { start in
                startIsIncluded(start, root: root, filter: filter)
                    && !skippedInside.contains { isPath(start, inOrAt: $0) }
            }, root: root, filter: filter, known: known, removed: try index.removedPathSet(),
            skipped: skippedInside, index: index,
            controller: controller,
            readers: readers,
            access: access, control: control, counter: ProgressCounter(progress),
            batchSize: batchSize, rescansModifiedFiles: options.rescansModifiedFiles,
            rootIsThere: { directoryDevice(root) == device })
        let outcome = try pipeline.run()
        summary.read = outcome.read
        summary.failed = outcome.failed
        summary.unchanged = outcome.unchanged
        summary.otherFiles = outcome.otherFiles
        // Only the walk's own unreadable paths and the folder's protect it from removals, so the
        // count line below can't, whatever kind it names.
        let protected =
            summary.issues.filter { $0.kind == .unreadable }.map(\.path) + outcome.unreadablePaths
        summary.issues += outcome.issues
        if let first = outcome.firstMoreIssue {
            summary.issues.append(
                ScanIssue(
                    kind: first.kind, path: root,
                    detail: "\(outcome.moreIssues) more problems in this folder, not listed;"
                        + " the first: \(first.path): \(first.detail)"))
        }
        summary.readers = outcome.readers
        summary.readCost = outcome.readCost
        summary.idleReaderSeconds = outcome.idleReaderSeconds
        summary.windows = outcome.windows
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
        // A volume that lists a file twice can leave others out with no error, as the NAS did
        // on 8 Nov (ADR 0151), so what the walk didn't see isn't known to be gone.
        if let first = outcome.firstListedTwice {
            summary.issues.append(
                ScanIssue(
                    kind: .listedTwice, path: root,
                    detail: "listed \(outcome.listedTwice) files more than once, the first"
                        + " \(first); the index keeps the files it didn't see"))
            logger.error(
                "\(root) listed \(outcome.listedTwice) files more than once; nothing removed")
            return summary
        }

        // The walk finished, so remove what's gone, except under anything it couldn't see, and
        // nothing when the owner keeps missing tracks.
        let gone = known.filter { path, _ in
            options.removesMissingTracks && !outcome.seen.contains(path)
                && !protected.contains { $0 == path || isPath(path, under: $0) }
        }
        try index.remove(gone.map(\.value.id))
        summary.removed = gone.count
        // A scan that changed nothing can't have made a move.
        let moves = summary.read > 0 || summary.removed > 0 ? try index.matchMoves() : []
        for move in moves { logger.notice("moved the stats of \(move.from) to \(move.to)") }
        summary.moved = moves.count
        try index.deleteOrphans()
        if subtrees.isEmpty { try index.setFinishedWholeScan(of: root, startedAt: started) }
        try index.checkpoint()
        logger.info(
            "scanned \(root): \(summary.read) read, \(summary.unchanged) unchanged, \(summary.removed) removed, \(summary.moved) moved, \(summary.issues.count) issues"
        )
        return summary
    }

    /// Reads the files at `paths` again and stores what they hold now, whatever their size and
    /// mtime say: the tag editor just wrote them, and a folder scan would wait behind other
    /// scans and, on a network volume, for playback. A file the index doesn't hold is skipped,
    /// since only a folder scan knows whether its folder includes it. A file in `parsed`, as
    /// the tag writer read it back, is stored from that rather than read again, while its size
    /// and mtime are still the ones it was parsed at; on a NAS that saves its opens and reads.
    /// Blocks, so call it off the main thread and outside Swift concurrency's threads.
    public func rescan(files paths: [String], parsed: [String: StampedParse] = [:]) throws
        -> ScanSummary
    {
        let index = try LibraryIndex(at: databaseURL)
        var summary = ScanSummary()
        let given = Dictionary(
            parsed.map { (canonicalPath($0.key), $0.value) },
            uniquingKeysWith: { first, _ in first })
        var targets: [(path: String, known: KnownFile)] = []
        for path in paths.map(canonicalPath) {
            guard let known = try index.knownFile(at: path) else {
                logger.notice("not reading \(path) again: the index doesn't hold it")
                continue
            }
            targets.append((path, known))
        }
        let found = targets
        let results = RescanResults(count: found.count)
        DispatchQueue.concurrentPerform(iterations: found.count) { position in
            let (path, known) = found[position]
            results.store(scannedAgain(path, known: known, parsed: given[path]), at: position)
        }
        var files: [ScannedFile] = []
        for result in results.all {
            switch result {
            case .file(let file)?:
                files.append(file)
                summary.read += 1
                if case .failure = file.outcome { summary.failed += 1 }
            case .issue(let issue)?: summary.issues.append(issue)
            case nil: break
            }
        }
        if !files.isEmpty {
            try index.store(files)
            // An edit can leave an album, artist or genre with no tracks.
            try index.deleteOrphans()
        }
        logger.info(
            "read \(summary.read) edited files again, \(summary.failed) failed, \(summary.issues.count) issues"
        )
        return summary
    }

    /// The file at `path` read again, or as `parsed` says it reads if it hasn't changed since,
    /// with its size and mtime as a directory listing gives them, so the next folder scan finds
    /// it unchanged.
    private func scannedAgain(_ path: String, known: KnownFile, parsed: StampedParse?)
        -> Rescanned
    {
        let values: URLResourceValues
        do {
            values = try URL(fileURLWithPath: path, isDirectory: false).resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey, .creationDateKey,
            ])
        } catch {
            return .issue(
                ScanIssue(kind: .unreadable, path: path, detail: "\(error.localizedDescription)"))
        }
        guard let size = values.fileSize, let modified = values.contentModificationDate else {
            return .issue(ScanIssue(kind: .unreadable, path: path, detail: noSizeOrMtime))
        }
        // After the size and mtime stored, so a change between them and this stat makes the
        // parse stale and the file is read again; the next folder scan then reads it once more.
        let parsed = parsed.flatMap { stamp -> ParsedFile? in
            var info = stat()
            guard lstat(path, &info) == 0, Int(info.st_size) == stamp.sizeBytes,
                Int(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int(info.st_mtimespec.tv_nsec)
                    == stamp.modifiedNanoseconds
            else { return nil }
            return stamp.parsed
        }
        return .file(
            ScannedFile(
                path: path, sizeBytes: size, modifiedSeconds: modified.timeIntervalSince1970,
                createdSeconds: values.creationDate?.timeIntervalSince1970, known: known,
                outcome: Result { () throws(MetadataError) -> ParsedFile in
                    if let parsed { return parsed }
                    return try access.readMetadata(at: path)
                }))
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

/// One file `rescan(files:)` read, or why it couldn't stat it.
private enum Rescanned {
    case file(ScannedFile)
    case issue(ScanIssue)
}

/// What `rescan(files:)` read of each file, by position, filled in from several threads.
private final class RescanResults: @unchecked Sendable {
    // `results` is guarded by `lock`.
    private let lock = NSLock()
    private var results: [Rescanned?]

    init(count: Int) { results = Array(repeating: nil, count: count) }

    func store(_ result: Rescanned, at position: Int) {
        lock.withLock { results[position] = result }
    }

    var all: [Rescanned?] { lock.withLock { results } }
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
