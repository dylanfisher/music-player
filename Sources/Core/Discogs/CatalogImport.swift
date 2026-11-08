import Foundation
import Log
import SQLite
import Settings

private let logger = moduleLogger()

/// What an import made.
public struct CatalogImportSummary: Equatable, Sendable {
    public var dumpDate: String
    public var records: [DumpKind: Int]
    /// The compressed bytes read: the whole dump set.
    public var compressedBytes: Int
    /// The new catalog's size.
    public var catalogBytes: Int
    public var seconds: Double
    /// The compressed bytes a stopped import had read, which this one carried on after; 0 for
    /// an import from the start.
    public var resumedBytes: Int
}

/// An import that stopped before it finished, which the next import of its dump set carries
/// on from (ADR 0134).
public struct UnfinishedImport: Equatable, Sendable {
    public var dumpDate: String
    /// How far it got, from 0 to 1, by the compressed bytes read.
    public var fraction: Double
}

/// The least time between two progress reports: a few a second however many records go by.
private let reportIntervalSeconds = 0.25

/// The compressed bytes read between two checkpoints: about two minutes of the real import on
/// this Mac (ADR 0134). A stop takes a checkpoint of its own.
let checkpointBytes = 1 << 30

/// Imports the newest complete dump set in `folder` into a new catalog, and replaces the file
/// at `catalog` with it once every file is read, matches its checksum, and the indexes are
/// built (ADR 0130). An unfinished import of the same set, left by a stop, a quit or a crash,
/// is carried on from its checkpoint unless `startingOver` (ADR 0134); one of another set is
/// removed. A stop by cancelling the task takes a checkpoint and throws
/// `CatalogImportError.stopped`, keeping the unfinished catalog to resume, as a failure to read
/// the dumps does; any other failure removes it and throws. The old catalog stays as it was,
/// in use, either way. `watchedFolders` are the watched folders' paths as they're found now:
/// the catalog must be outside all of them. `checkpointBytes` is how many compressed bytes go
/// between checkpoints, for tests; nil for the usual. `progress` hears each step, a few times a
/// second and after each checkpoint, off the main thread. One import at a time may write a
/// catalog.
public func importCatalog(
    from folder: URL, to catalog: URL, outsideOf watchedFolders: [String],
    startingOver: Bool = false, checkpointBytes: Int? = nil,
    progress: @escaping @Sendable (CatalogImportProgress) -> Void
) async throws -> CatalogImportSummary {
    let task = Task.detached(priority: .utility) {
        try runImport(
            from: folder, to: catalog, outsideOf: watchedFolders, startingOver: startingOver,
            checkpointBytes: checkpointBytes ?? Discogs.checkpointBytes, progress: progress)
    }
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}

/// The import of `catalog` that stopped before it finished, if its checkpoint is whole. Opening
/// it rolls back a transaction a killed import left open.
public func unfinishedImport(of catalog: URL) -> UnfinishedImport? {
    let building = unfinishedFile(of: catalog)
    guard FileManager.default.fileExists(atPath: building.path) else { return nil }
    do {
        let checkpoint = try readCheckpoint(at: building)
        return UnfinishedImport(
            dumpDate: checkpoint.dumpDate,
            fraction: min(1, Double(checkpoint.bytesRead) / Double(max(checkpoint.totalBytes, 1))))
    } catch {
        logger.notice("the unfinished Discogs import \(building.path) can't be resumed: \(error)")
        return nil
    }
}

/// `importCatalog`'s work, on the calling thread; it stops when the calling task is cancelled.
/// `batchBytes` is for tests, as `DumpBatches` takes it.
func runImport(
    from folder: URL, to catalog: URL, outsideOf watchedFolders: [String],
    startingOver: Bool = false, batchBytes: Int = DumpBatches.batchBytes,
    checkpointBytes: Int = checkpointBytes, progress report: (CatalogImportProgress) -> Void
) throws(CatalogImportError) -> CatalogImportSummary {
    let started = Date()
    let catalogPath = comparable(catalog.path)
    if let watched = watchedFolders.first(where: { isPath(catalogPath, inOrAt: comparable($0)) }) {
        throw .catalogInsideWatchedFolder(catalog: catalog.path, folder: watched)
    }
    let set = try DumpSet.newest(in: folder)
    let building = unfinishedFile(of: catalog)
    var catalogBytes = 0
    var progress = CatalogImportProgress(
        stage: .reading(.labels), dumpDate: set.date, bytesRead: 0,
        totalBytes: set.compressedBytes, records: [:])
    var checkpoint = ImportCheckpoint(starting: set)
    var resumedBytes = 0
    do {
        try FileManager.default.createDirectory(
            at: catalog.deletingLastPathComponent(), withIntermediateDirectories: true)
        let resumed = startingOver ? nil : resumableCheckpoint(at: building, of: set)
        if let resumed {
            checkpoint = resumed
            resumedBytes = resumed.bytesRead
            logger.notice(
                "resuming the import of the Discogs dump of \(set.date) from \(folder.path) after \(resumedBytes) of \(set.compressedBytes) bytes"
            )
        } else {
            logger.notice("importing the Discogs dump of \(set.date) from \(folder.path)")
        }
        if !checkpoint.indexed {
            try build(
                set, into: building, resuming: resumed != nil, from: &checkpoint,
                options: ImportOptions(batchBytes: batchBytes, checkpointBytes: checkpointBytes),
                progress: &progress, report: report)
        }
        try flush(building)
        catalogBytes = try Database.sizeBytes(at: building)
        // rename(2) replaces the old file in one step: a reader opens the old catalog or the
        // new one, never part of either. One that has the old one open reads on in it, or
        // gets an I/O error from the system SQLite, so it opens the new one.
        guard rename(building.path, catalog.path) == 0 else {
            throw CatalogImportError.unwritable(catalog.path, String(cString: strerror(errno)))
        }
    } catch {
        // Anything but the dumps' own errors is the catalog's file or its database.
        let failure = error as? CatalogImportError ?? .unwritable(building.path, "\(error)")
        switch failure {
        case .stopped, .unreadable:
            // A stop, or dumps that couldn't be read, as on a share that was disconnected:
            // the next import carries on from the last checkpoint.
            logger.notice("the Discogs import of \(set.date) stopped, to resume: \(failure)")
        default:
            do {
                try removeDatabase(at: building)
            } catch let removal {
                logger.error("couldn't remove the unfinished catalog \(building.path): \(removal)")
            }
            logger.error("the Discogs import of \(set.date) failed: \(failure)")
        }
        throw failure
    }
    progress.stage = .finished
    progress.bytesRead = set.compressedBytes
    progress.records = recordCounts(checkpoint)
    report(progress)
    logger.notice("imported the Discogs dump of \(set.date) into \(catalog.path)")
    return CatalogImportSummary(
        dumpDate: set.date, records: recordCounts(checkpoint),
        compressedBytes: set.compressedBytes, catalogBytes: catalogBytes,
        seconds: Date().timeIntervalSince(started), resumedBytes: resumedBytes)
}

/// The file an import of `catalog` builds, beside it.
private func unfinishedFile(of catalog: URL) -> URL {
    catalog.appendingPathExtension("importing")
}

/// The checkpoint in the unfinished catalog at `url`.
private func readCheckpoint(at url: URL) throws -> ImportCheckpoint {
    try ImportCheckpoint.read(from: try Database(rollbackJournalAt: url, creating: false))
}

/// The checkpoint to carry on an import of `set` from, if the unfinished catalog at `url` has
/// one that's whole and of `set`; nil to start over, which replaces the file.
private func resumableCheckpoint(at url: URL, of set: DumpSet) -> ImportCheckpoint? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    do {
        let checkpoint = try readCheckpoint(at: url)
        guard checkpoint.belongs(to: set) else {
            logger.notice(
                "the unfinished catalog \(url.path) is of the \(checkpoint.dumpDate) dump, or another build: starting over"
            )
            return nil
        }
        return checkpoint
    } catch {
        logger.notice("the unfinished catalog \(url.path) has no whole checkpoint: starting over")
        return nil
    }
}

private func recordCounts(_ checkpoint: ImportCheckpoint) -> [DumpKind: Int] {
    Dictionary(uniqueKeysWithValues: DumpKind.allCases.map { ($0, checkpoint.count($0)) })
}

/// How the import cuts its work, which tests make small.
private struct ImportOptions {
    var batchBytes: Int
    var checkpointBytes: Int
}

/// Writes the catalog of `set` at `url`, from `checkpoint` when `resuming`, and closes it.
/// `checkpoint` is the last one committed, once it returns or throws.
private func build(
    _ set: DumpSet, into url: URL, resuming: Bool, from checkpoint: inout ImportCheckpoint,
    options: ImportOptions, progress: inout CatalogImportProgress,
    report: (CatalogImportProgress) -> Void
) throws {
    let writer =
        resuming
        ? try BackgroundCatalogWriter(resumingAt: url)
        : try BackgroundCatalogWriter(creatingAt: url, checkpoint: checkpoint)
    // A failure leaves no batch writing to the file when it's removed.
    defer { writer.stop() }
    progress.records = recordCounts(checkpoint)
    progress.bytesRead = checkpoint.bytesRead
    var lastReport = Date.distantPast
    for kind in DumpKind.allCases.dropFirst(checkpoint.filesFinished) {
        progress.stage = .reading(kind)
        report(progress)
        var current = progress
        let bytesBefore = checkpoint.finishedBytes
        try read(set, kind, into: writer, from: &checkpoint, options: options) {
            stream, records, checkpointed in
            current.bytesRead = bytesBefore + stream.compressedBytesRead
            current.records[kind] = records
            if checkpointed || Date().timeIntervalSince(lastReport) >= reportIntervalSeconds {
                lastReport = Date()
                current.checkpointed = checkpointed
                report(current)
                current.checkpointed = false
            }
        }
        progress = current
        progress.bytesRead = checkpoint.finishedBytes
        let count = checkpoint.count(kind)
        progress.records[kind] = count
        logger.notice("imported \(count) \(kind.rawValue) of the \(set.date) dump")
    }
    if Task.isCancelled { throw CatalogImportError.stopped }
    progress.stage = .indexing
    report(progress)
    checkpoint.indexed = true
    try writer.finish(checkpoint)
}

/// Reads one dump of `set` into `writer`, from `checkpoint`'s position in it or from its
/// start, checking its hash at the end. A checkpoint is committed every
/// `options.checkpointBytes` and at the end, and `checkpoint` updated to it; a stop takes one
/// at the next access point and throws. `step` hears the stream and the record count after
/// each record, and after each checkpoint.
private func read(
    _ set: DumpSet, _ kind: DumpKind, into writer: BackgroundCatalogWriter,
    from checkpoint: inout ImportCheckpoint, options: ImportOptions,
    step: (GzipStream, Int, _ checkpointed: Bool) -> Void
) throws {
    guard let url = set.files[kind], let expected = set.checksums[kind] else {
        preconditionFailure("a complete set has every kind")
    }
    let name = url.lastPathComponent
    let position = checkpoint.position
    let stream = try GzipStream(
        file: url, resumingAt: position?.accessPoint, accessPointBytes: options.checkpointBytes)
    var batches = DumpBatches(
        stream, kind: kind, file: name, batchBytes: options.batchBytes, resuming: position?.record)
    var records = checkpoint.count(kind)
    var stopping = false
    // The parser, and with it `emit`, is gone once it has parsed.
    try withoutActuallyEscaping(step) { step in
        let dump = DumpParser(kind: kind, file: name) { record in
            try writer.add(record)
            records += 1
            step(stream, records, false)
        }
        while let batch = try batches.next() {
            if !dump.parse(batch.document, firstLine: batch.firstLine) {
                throw dump.failure
                    ?? CatalogImportError.malformed(name, line: batch.firstLine, "XMLParser stopped")
            }
            if let point = batch.accessPoint {
                checkpoint.records[kind.rawValue] = records
                checkpoint.position = .init(record: batch.end, accessPoint: point)
                try writer.checkpoint(checkpoint)
                step(stream, records, true)
                if stopping { throw CatalogImportError.stopped }
            }
            if !stopping, Task.isCancelled {
                stopping = true
                stream.requestAccessPoint()
            }
        }
    }
    guard stream.isComplete else { throw CatalogImportError.truncated(name) }
    let actual = stream.sha256()
    guard actual == expected else {
        throw CatalogImportError.checksumMismatch(name, expected: expected, actual: actual)
    }
    checkpoint.records[kind.rawValue] = records
    checkpoint.filesFinished += 1
    checkpoint.finishedBytes += stream.compressedBytesRead
    checkpoint.position = nil
    try writer.checkpoint(checkpoint)
    step(stream, records, true)
    if stopping { throw CatalogImportError.stopped }
}

/// Writes the new catalog through to the disk before it replaces the old one, since it was
/// written without syncs.
private func flush(_ url: URL) throws {
    let handle = try FileHandle(forUpdating: url)
    try handle.synchronize()
    try handle.close()
}

/// `path` with `.`, `..` and repeated slashes resolved, in NFC, to compare with another.
private func comparable(_ path: String) -> String {
    (path.precomposedStringWithCanonicalMapping as NSString).standardizingPath
}
