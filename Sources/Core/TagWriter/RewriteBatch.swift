import Foundation
import Log
import Metadata

private let logger = moduleLogger()

/// One file of a batch to write through its temp file: read and planned, with the old bytes
/// its undo needs, not yet copied.
struct RewriteJob {
    var path: String
    var segments: [Segment]
    var restore: [TagUndoJournal.RestoreSegment]
    var oldBytes: [[UInt8]]
    var original: TagFile
    var before: FileIdentity
    var expected: TagWriter.Expected
}

/// Files a batch rewrites through their temp files at once (ADR 0196). On a NAS a rewrite waits
/// on hundreds of round trips as well as its copy, which others in flight hide. Scaled with the
/// Mac as reads are (ADR 0074), with the in-place writes' 4 as the floor, which is what the
/// 2015 MacBook Pro gets; at most 8, since each holds a 4 MB copy buffer, a 4 MB read-back
/// buffer and its tag bytes.
let rewritesAtOnce = max(writesAtOnce, min(filesReadAtOnce, 8))

/// The rewrites of one batch under way, each on a thread of its own, at most `rewritesAtOnce`
/// at a time, and what each came to.
final class Rewrites: @unchecked Sendable {
    // `finished` and `stopped` are guarded by `lock`.
    private let lock = NSLock()
    private var finished: [Int: JobResult] = [:]
    private var stopped = false
    private let slots = DispatchSemaphore(value: rewritesAtOnce)
    private let running = DispatchGroup()
    /// Held for each journal call a rewrite makes, so they run one at a time.
    private let journal = NSLock()

    /// Whether a rewrite failed in a way that stops the batch: a full disk or a journal that
    /// can't be written.
    var hasStopped: Bool { lock.withLock { stopped } }

    /// Runs `work`, the rewrite of the batch's file at `index`, on a thread of its own, once
    /// fewer than `rewritesAtOnce` are under way; until then, blocks. A batch stopped meanwhile
    /// doesn't run it, and the file has no result.
    func start(_ index: Int, _ work: @escaping @Sendable () -> JobResult) {
        slots.wait()
        guard !hasStopped else {
            slots.signal()
            return
        }
        running.enter()
        Thread { [self] in
            let result = work()
            lock.withLock {
                finished[index] = result
                if case .failure(let error) = result, error.stopsBatch { stopped = true }
            }
            slots.signal()
            running.leave()
        }.start()
    }

    /// Runs `call`, a rewrite's call on the journal, once no other rewrite's is running.
    func journaling<T>(_ call: () throws(TagWriteError) -> T) throws(TagWriteError) -> T {
        journal.lock()
        defer { journal.unlock() }
        return try call()
    }

    /// Waits for the rewrites under way, and hands back what each came to since the last call,
    /// by its index in the batch.
    func finish() -> [Int: JobResult] {
        running.wait()
        return lock.withLock {
            defer { finished = [:] }
            return finished
        }
    }
}

extension TagWriter {
    /// Writes one file through its temp file, beside the batch's other rewrites, so it touches
    /// only its own file and temp file, and the journal only through `rewrites.journaling`. The
    /// steps are in the order ADR 0107 gives them: the temp file written, hashing the original
    /// as it's copied (ADR 0196), and read back; then the record and old bytes; then the
    /// rename; then the record brought up to the renamed file.
    func rewrite(_ job: RewriteJob, entry: TagUndoJournal.Entry, _ rewrites: Rewrites)
        throws(TagWriteError) -> Outcome
    {
        let path = job.path
        let temp = try writeTemp(
            job.segments, from: path, identity: job.before, hashing: job.original.payload,
            faults: faults)
        guard let hashes = temp.originalHashes else {
            preconditionFailure("a temp file asked for the hashes has them")
        }
        var handle: TagUndoJournal.Handle?
        var record: TagUndoJournal.FileRecord
        let parsed: ParsedFile
        do throws(TagWriteError) {
            parsed = try checkEdited(
                temp.path, original: job.original, path: path, hashes: hashes,
                expected: job.expected)
            record = TagUndoJournal.FileRecord(
                path: path, edited: try identity(temp.path), original: job.before,
                originalSHA256: Data(hashes.full), restore: job.restore)
            handle = try rewrites.journaling { () throws(TagWriteError) in
                try journal.append(record, oldBytes: job.oldBytes, to: entry)
            }
            try finish(path, temp: temp, before: job.before)
        } catch {
            // A crash leaves the temp file and the journal as they are.
            if error.detail == crashDetail { throw error }
            unlink(temp.path)
            if let handle {
                do throws(TagWriteError) {
                    try rewrites.journaling { () throws(TagWriteError) in
                        try journal.remove(handle)
                    }
                } catch let journalError {
                    logger.error("\(journalError.description)")
                }
            }
            throw error
        }
        logger.notice("wrote tags to \(path)")
        // Undo compares against the file as it is now; a volume may round the mtime or change
        // the inode on the rename.
        do throws(TagWriteError) {
            let final = try identity(path)
            if !record.isEdited(final) {
                record.setEdited(final)
                try rewrites.journaling { () throws(TagWriteError) in
                    try journal.update(record, at: handle!)
                }
            }
            // Stamped as the renamed file is, so a rescan that stats it finds the same.
            return .changed(final.stamp(parsed), problem: nil)
        } catch {
            logger.error("\(error.description)")
            return .changed(
                temp.identity.stamp(parsed),
                problem: TagWriteError(
                    path: path, kind: .journal,
                    detail: "written, but its undo record couldn't be updated: \(error.detail)"))
        }
    }
}
