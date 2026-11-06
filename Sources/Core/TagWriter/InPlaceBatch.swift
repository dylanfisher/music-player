import Foundation
import Log
import Metadata

private let logger = moduleLogger()

/// One file of a batch to write in place: read, planned, and its planned file read back, not
/// yet journaled.
struct InPlaceJob {
    var path: String
    var plan: InPlacePlan
    var before: FileIdentity
    var original: TagFile
    var expected: TagWriter.Expected

    /// What the job holds in memory, which bounds a chunk.
    var bytes: Int { plan.oldBytes.count + plan.newBytes.count + (expected.art?.count ?? 0) }
}

/// The steps of a chunk of writes in place, after each of which `WriteFaults.crashAfter` can
/// stop the batch as a crash there would, leaving the files and the journal as they are.
enum BatchStep: CaseIterable, Sendable {
    /// Every record, its old bytes and its marker are journaled and flushed.
    case journaled
    /// The chunk's first file is written whole; the others aren't started.
    case firstWritten
    /// Every file is written and flushed with `fsync`, before the drive's cache is.
    case written
    /// The drive's cache is flushed, before any record is confirmed.
    case flushed
    /// The first file's record is confirmed.
    case firstConfirmed
}

/// Files a batch writes and reads back at once: SMB is bound by round trips, so a few in
/// flight hide each other's (ADR 0108). Its journal steps stay one at a time.
private let writesAtOnce = 4
/// The most files, and the most of their tag bytes, a chunk of a batch plans before it writes,
/// so a change to a thousand files' art doesn't hold every plan at once.
let chunkFiles = 32
let chunkBytes = 64 * 1024 * 1024

/// What became of one file of a chunk.
typealias JobResult = Result<TagWriter.Outcome, TagWriteError>

extension TagWriter {
    /// Writes a chunk of a batch in place (ADR 0108): every record, its old bytes and its marker
    /// journaled with one flush of the drive's cache; then the writes and their read-backs,
    /// `writesAtOnce` at a time; then one flush of the drive's cache per volume written; then
    /// each record confirmed. A file whose write or read-back fails is put back from the
    /// journal. Returns each file's result in order, and whether the batch stops after the
    /// chunk: a full disk or a journal that can't be written, or a crash `faults` injects.
    func writeInPlace(
        _ jobs: [InPlaceJob], entry: TagUndoJournal.Entry, progress: WriteProgressCounter
    ) -> (results: [JobResult], stop: Bool, crashed: Bool) {
        var records = jobs.map { job in
            TagUndoJournal.FileRecord(
                path: job.path, edited: job.before, original: job.before, originalSHA256: nil,
                restore: job.plan.restore(size: job.before.size), inPlace: job.plan.journaled)
        }
        let handles: [TagUndoJournal.Handle]
        do throws(TagWriteError) {
            handles = try journal.appendInPlace(
                Array(zip(records, jobs.map(\.plan.oldBytes))), to: entry)
        } catch {
            logger.error("\(error.description)")
            for _ in jobs { progress.written() }
            return (jobs.map { _ in .failure(error) }, error.stopsBatch, false)
        }
        if faults.crashAfter == .journaled { return ([], true, true) }

        let writes = concurrently(jobs.count, atOnce: writesAtOnce) { index in
            if faults.crashAfter == .firstWritten, index > 0 { return Written.skipped }
            defer { progress.written() }
            return autoreleasepool { write(jobs[index]) }
        }
        if faults.crashAfter == .firstWritten || faults.crashAfter == .written
            || writes.contains(where: { if case .crashed = $0 { true } else { false } })
        {
            return ([], true, true)
        }
        var flushed = writes
        for (device, indices) in Dictionary(grouping: jobs.indices, by: { jobs[$0].before.device })
        {
            let written = indices.filter { if case .written = writes[$0] { true } else { false } }
            guard let first = written.first else { continue }
            do throws(TagWriteError) {
                try flushDrive(of: jobs[first].path, faults: faults)
            } catch {
                logger.error("couldn't flush device \(device): \(error.description)")
                for index in written { flushed[index] = .failed(error, wrote: true) }
            }
        }
        if faults.crashAfter == .flushed { return ([], true, true) }

        var results: [JobResult] = []
        for (index, job) in jobs.enumerated() {
            switch flushed[index] {
            case .written(let parsed, let identity):
                logger.notice("wrote tags in place to \(job.path)")
                records[index].setEdited(identity)
                do throws(TagWriteError) {
                    try journal.confirm(records[index], at: handles[index])
                    results.append(.success(.changed(identity.stamp(parsed), problem: nil)))
                } catch {
                    logger.error("\(error.description)")
                    results.append(
                        .success(
                            .changed(
                                identity.stamp(parsed),
                                problem: TagWriteError(
                                    path: job.path, kind: .journal,
                                    detail: "written, but its undo record couldn't be confirmed:"
                                        + " \(error.detail)"))))
                }
                if faults.crashAfter == .firstConfirmed { return ([], true, true) }
            case .failed(let error, let wrote):
                results.append(
                    .failure(
                        putBack(job, record: records[index], at: handles[index], error, wrote)))
            case .skipped, .crashed:
                preconditionFailure("a crash returns before the confirmations")
            }
        }
        // A full disk stops the files after the chunk, as it stops those after a temp file.
        let stop = results.contains {
            if case .failure(let error) = $0 { error.stopsBatch } else { false }
        }
        return (results, stop, false)
    }

    /// What one file's write and read-back came to.
    private enum Written {
        case written(ParsedFile, FileIdentity)
        case failed(TagWriteError, wrote: Bool)
        /// Stopped as a crash would, by `faults`.
        case crashed
        case skipped
    }

    /// Writes one file of a chunk over its old tags and reads it back. Runs beside the chunk's
    /// other writes, so it touches only its own file, never the journal.
    private func write(_ job: InPlaceJob) -> Written {
        var wrote = false
        do throws(TagWriteError) {
            if let hook = faults.beforeReplacing {
                do {
                    try hook(job.path, nil)
                } catch let error as TagWriteError {
                    // As a full disk, which the tests inject here.
                    throw error
                } catch {
                    throw TagWriteError(path: job.path, kind: .writeFailed, detail: "\(error)")
                }
            }
            try overwrite(
                job.path, with: job.plan, identity: job.before, faults: faults, wrote: &wrote)
            if let hook = faults.afterOverwriting {
                do {
                    try hook(job.path)
                } catch {
                    throw TagWriteError(path: job.path, kind: .writeFailed, detail: "\(error)")
                }
            }
            // Before the read-back, so a change another app makes after it shows as a newer
            // mtime than the parse's, and the rescan reads the file again.
            let written = try identity(job.path)
            let parsed = try readBack(
                job.plan, path: job.path, original: job.original, expected: job.expected)
            return .written(parsed, written)
        } catch {
            if error.detail == crashDetail { return .crashed }
            logger.error("\(error.description)")
            return .failed(error, wrote: wrote)
        }
    }

    /// Takes a file whose write failed out of the journal, putting the original back first if
    /// a byte may have reached it; returns the failure to report.
    private func putBack(
        _ job: InPlaceJob, record: TagUndoJournal.FileRecord, at handle: TagUndoJournal.Handle,
        _ error: TagWriteError, _ wrote: Bool
    ) -> TagWriteError {
        guard wrote else {
            do throws(TagWriteError) {
                try journal.remove(handle)
            } catch let journalError {
                logger.error("\(journalError.description)")
            }
            return error
        }
        do throws(TagWriteError) {
            _ = try putBackOriginal(record, at: handle, oldBytes: job.plan.oldBytes)
        } catch let putBack {
            logger.error("\(putBack.description)")
            return TagWriteError(
                path: job.path, kind: error.kind,
                detail: "\(error.detail); the original isn't put back yet, and the next write or"
                    + " undo tries again: \(putBack.detail)")
        }
        return error
    }
}

/// Runs `work` for each of `count` indices, at most `atOnce` at a time, and returns what each
/// gave, in order. Each worker is a thread of its own: the work blocks on file I/O, and
/// `concurrentPerform` runs its iterations one after another when the pool's threads are busy.
private func concurrently<T: Sendable>(
    _ count: Int, atOnce: Int, _ work: @escaping @Sendable (Int) -> T
) -> [T] {
    let slots = Slots<T>(count: count)
    let done = DispatchGroup()
    for _ in 0..<min(atOnce, count) {
        done.enter()
        Thread {
            while let index = slots.nextIndex() { slots.store(work(index), at: index) }
            done.leave()
        }.start()
    }
    done.wait()
    return slots.values
}

/// What `concurrently` hands out and gets back, from several threads.
private final class Slots<T>: @unchecked Sendable {
    // `results` and `next` are guarded by `lock`.
    private let lock = NSLock()
    private var results: [T?]
    private var next = 0

    init(count: Int) { results = Array(repeating: nil, count: count) }

    /// The next index no thread has taken, or nil once every one is.
    func nextIndex() -> Int? {
        lock.withLock {
            guard next < results.count else { return nil }
            defer { next += 1 }
            return next
        }
    }

    func store(_ result: T, at index: Int) { lock.withLock { results[index] = result } }

    var values: [T] { lock.withLock { results.map { $0! } } }
}
