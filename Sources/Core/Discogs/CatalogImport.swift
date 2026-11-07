import Foundation
import Log
import SQLite
import Settings

private let logger = moduleLogger()

/// What an import made.
struct CatalogImportSummary: Equatable, Sendable {
    var dumpDate: String
    var records: [DumpKind: Int]
    /// The compressed bytes read: the whole dump set.
    var compressedBytes: Int
    /// The new catalog's size.
    var catalogBytes: Int
    var seconds: Double
}

/// The least time between two progress reports: a few a second however many records go by.
private let reportIntervalSeconds = 0.25

/// Imports the newest complete dump set in `folder` into a new catalog, and replaces the file
/// at `catalog` with it once every file is read, matches its checksum, and the indexes are
/// built (ADR 0130). A failure, or a stop by cancelling the task, removes the new file and
/// throws a `CatalogImportError`; the old catalog stays as it was, in use. `watchedFolders`
/// are the watched folders' paths as they're found now: the catalog must be outside all of
/// them. `progress` hears each step, a few times a second, off the main thread. One import
/// at a time may write a catalog.
func importCatalog(
    from folder: URL, to catalog: URL, outsideOf watchedFolders: [String],
    progress: @escaping @Sendable (CatalogImportProgress) -> Void
) async throws -> CatalogImportSummary {
    let task = Task.detached(priority: .utility) {
        try runImport(
            from: folder, to: catalog, outsideOf: watchedFolders, progress: progress)
    }
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}

/// `importCatalog`'s work, on the calling thread; it stops when the calling task is cancelled.
func runImport(
    from folder: URL, to catalog: URL, outsideOf watchedFolders: [String],
    progress report: (CatalogImportProgress) -> Void
) throws(CatalogImportError) -> CatalogImportSummary {
    let started = Date()
    let catalogPath = comparable(catalog.path)
    if let watched = watchedFolders.first(where: { isPath(catalogPath, inOrAt: comparable($0)) }) {
        throw .catalogInsideWatchedFolder(catalog: catalog.path, folder: watched)
    }
    let set = try DumpSet.newest(in: folder)
    logger.notice("importing the Discogs dump of \(set.date) from \(folder.path)")
    let building = catalog.appendingPathExtension("importing")
    var catalogBytes = 0
    var progress = CatalogImportProgress(
        stage: .reading(.labels), dumpDate: set.date, bytesRead: 0,
        totalBytes: set.compressedBytes, records: [:])
    do {
        try FileManager.default.createDirectory(
            at: catalog.deletingLastPathComponent(), withIntermediateDirectories: true)
        try build(set, into: building, progress: &progress, report: report)
        try flush(building)
        catalogBytes = try Database.sizeBytes(at: building)
        // rename(2) replaces the old file in one step: a reader opens the old catalog or the
        // new one, never part of either. One that has the old one open gets an I/O error
        // from the system SQLite on its next read, so it opens the new one.
        guard rename(building.path, catalog.path) == 0 else {
            throw CatalogImportError.unreadable(
                building.lastPathComponent, String(cString: strerror(errno)))
        }
    } catch {
        do {
            try removeDatabase(at: building)
        } catch let removal {
            logger.error("couldn't remove the unfinished catalog \(building.path): \(removal)")
        }
        let failure = error as? CatalogImportError ?? .unreadable(building.path, "\(error)")
        logger.error("the Discogs import of \(set.date) failed: \(failure)")
        throw failure
    }
    progress.stage = .finished
    report(progress)
    logger.notice("imported the Discogs dump of \(set.date) into \(catalog.path)")
    return CatalogImportSummary(
        dumpDate: set.date, records: progress.records, compressedBytes: set.compressedBytes,
        catalogBytes: catalogBytes, seconds: Date().timeIntervalSince(started))
}

/// Writes the catalog of `set` at `url`, and closes it.
private func build(
    _ set: DumpSet, into url: URL, progress: inout CatalogImportProgress,
    report: (CatalogImportProgress) -> Void
) throws {
    let writer = try CatalogWriter(creatingAt: url)
    var lastReport = Date.distantPast
    var bytesBefore = 0
    for kind in DumpKind.allCases {
        progress.stage = .reading(kind)
        report(progress)
        var current = progress
        let bytes = try read(set, kind, into: writer) { stream, records in
            current.bytesRead = bytesBefore + stream.compressedBytesRead
            current.records[kind] = records
            if Date().timeIntervalSince(lastReport) >= reportIntervalSeconds {
                lastReport = Date()
                report(current)
            }
        }
        progress = current
        bytesBefore += bytes
        progress.bytesRead = bytesBefore
        let count = progress.records[kind] ?? 0
        progress.records[kind] = count
        logger.notice("imported \(count) \(kind.rawValue) of the \(set.date) dump")
    }
    if Task.isCancelled { throw CatalogImportError.stopped }
    progress.stage = .indexing
    report(progress)
    try writer.finish(dumpDate: set.date)
}

/// Reads one dump of `set` into `writer`, checking its hash at the end, and returns its
/// compressed size. `step` hears the stream and the record count after each record.
private func read(
    _ set: DumpSet, _ kind: DumpKind, into writer: CatalogWriter,
    step: (GzipStream, Int) -> Void
) throws -> Int {
    guard let url = set.files[kind], let expected = set.checksums[kind] else {
        preconditionFailure("a complete set has every kind")
    }
    let stream = try GzipStream(file: url)
    let parser = XMLParser(stream: stream)
    var records = 0
    // The parser, and with it `emit`, is gone once it has parsed.
    let failure = withoutActuallyEscaping(step) { step in
        let dump = DumpParser(kind: kind, file: url.lastPathComponent) { record in
            try writer.add(record)
            records += 1
            step(stream, records)
        }
        dump.parse(parser)
        return dump.failure
    }
    // The stream's own failure says more than the parser's error about the end of its input.
    if let failure = stream.failure { throw failure }
    if let failure { throw failure }
    if Task.isCancelled { throw CatalogImportError.stopped }
    guard stream.isComplete else { throw CatalogImportError.truncated(url.lastPathComponent) }
    let actual = stream.sha256()
    guard actual == expected else {
        throw CatalogImportError.checksumMismatch(
            url.lastPathComponent, expected: expected, actual: actual)
    }
    return stream.compressedBytesRead
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
