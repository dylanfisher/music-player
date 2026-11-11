import Foundation
import Log
import Metadata

private let logger = moduleLogger()

/// The only code that writes music files (AGENTS.md, ADR 0020). New tags that fit the room the
/// old ones had are checked, journaled and written over the old ones in place, then read back;
/// any other edit is written to a temp file beside the original, checked, and renamed over it,
/// so a failure at any step leaves the original as it was (ADR 0107). Every edit is journaled
/// so it can be undone.
///
/// Calls block on file I/O, which on a NAS is slow, so make them off the main thread, one at a
/// time.
public struct TagWriter: Sendable {
    public let journal: TagUndoJournal
    package var faults = WriteFaults()
    public init(journal: TagUndoJournal) {
        self.journal = journal
    }

    /// Writes `edit` into each of `paths`, as one undoable edit. A file the edit changes nothing
    /// in isn't written. Each file's failure is reported and the rest carry on, except a full
    /// disk or a journal that can't be written, which stop the batch after that file. A write
    /// in place an earlier call left unfinished is finished first.
    ///
    /// Files whose new tags fit are read and planned first, a chunk at a time, then written in
    /// place together (ADR 0108); any other file goes through its temp file when it's reached.
    /// `progress` is told of each file read and each written, from the threads writing them.
    /// The journal keeps `origin` with the edit, for `newestEdit()`.
    public func write(
        _ edit: TagEdit, to requested: [String], origin: TagEditOrigin = .tagEditor,
        progress: @escaping @Sendable (TagWriteProgress) -> Void = { _ in }
    ) -> TagWriteReport {
        write(requested.map { (path: $0, edit: edit) }, origin: origin, progress: progress)
    }

    /// Writes each file's own edit, as one undoable edit, the way `write(_:to:)` writes one
    /// edit to them all: the Discogs tagger writes each track its release's values (ADR 0133).
    /// A path named twice is written with its first edit only.
    public func write(
        _ requested: [(path: String, edit: TagEdit)], origin: TagEditOrigin = .tagEditor,
        progress: @escaping @Sendable (TagWriteProgress) -> Void = { _ in }
    ) -> TagWriteReport {
        // Once each, so a path named twice isn't written by two threads at once.
        var named = Set<String>()
        let files = requested.filter { named.insert($0.path).inserted }
        let paths = files.map(\.path)
        let counter = WriteProgressCounter(total: paths.count, report: progress)
        var report = recoverInterrupted()
        let entry: TagUndoJournal.Entry
        do {
            entry = try journal.newEntry(origin: origin)
        } catch {
            report.failures.append(error)
            report.notWritten = paths
            return report
        }
        let unclear = removeLeftoverTemps(for: paths, faults)
        var results = [JobResult?](repeating: nil, count: paths.count)
        var chunk: [(index: Int, job: InPlaceJob)] = []
        // Writes the planned chunk; returns whether the batch stops after it, and whether as a
        // crash would, which leaves the journal as it is.
        func writeChunk() -> (stop: Bool, crashed: Bool) {
            guard !chunk.isEmpty else { return (false, false) }
            let (written, stop, crashed) = writeInPlace(
                chunk.map(\.job), entry: entry, progress: counter)
            for (item, result) in zip(chunk, written) { results[item.index] = result }
            chunk = []
            return (stop, crashed)
        }
        // The files up to where the batch stopped.
        var reached = paths.count
        files: for (index, path) in paths.enumerated() {
            // A batch can run over an album of large files; each file's buffers go before the
            // next, but for a chunk's plans.
            let prepared = autoreleasepool { () -> Result<Prepared, TagWriteError> in
                do throws(TagWriteError) {
                    if let error = unclear[path] { throw error }
                    return .success(try prepare(files[index].edit, path, entry: entry))
                } catch {
                    logger.error("\(error.description)")
                    return .failure(error)
                }
            }
            counter.read()
            switch prepared {
            case .success(.done(let outcome)):
                results[index] = .success(outcome)
                counter.written()
            case .success(.inPlace(let job)):
                chunk.append((index, job))
                guard chunk.count >= chunkFiles || chunk.map(\.job.bytes).reduce(0, +) >= chunkBytes
                else { continue }
                let (stop, crashed) = writeChunk()
                if crashed { return report }
                if stop {
                    reached = index + 1
                    break files
                }
            case .failure(let error):
                results[index] = .failure(error)
                counter.written()
                if error.stopsBatch {
                    reached = index + 1
                    break files
                }
            }
        }
        // The chunk's files come before any file that stopped the batch.
        if writeChunk().crashed { return report }
        for (index, result) in results.prefix(reached).enumerated() {
            switch result {
            case .success(.unchanged): report.unchanged.append(paths[index])
            case .success(.changed(let parsed, let problem)):
                report.changed.append(paths[index])
                report.parsed[paths[index]] = parsed
                if let problem { report.failures.append(problem) }
            case .failure(let error): report.failures.append(error)
            case nil: preconditionFailure("every file up to the stop has a result")
            }
        }
        report.notWritten = Array(paths[reached...])
        if !report.notWritten.isEmpty {
            logger.error("stopped the batch; \(report.notWritten.count) files weren't written")
        }
        do throws(TagWriteError) {
            try journal.removeIfEmpty(entry)
            try journal.prune()
        } catch {
            report.failures.append(error)
        }
        return report
    }

    /// The newest journaled edit, nil when there is nothing to undo. Changes nothing.
    public func newestEdit() throws(TagWriteError) -> JournaledEdit? {
        try journal.newestEdit()
    }

    /// Undoes the newest edit only while it is still `expected`, the one Undo Tag Edit asked
    /// about (nil for none); an edit made since fails the undo with nothing undone, rather than
    /// undoing an edit nobody was asked about (ADR 0136).
    public func undoLast(ifNewestIs expected: JournaledEdit?) -> TagWriteReport {
        var report = TagWriteReport()
        do throws(TagWriteError) {
            if try journal.newestEdit() == expected { return undoLast() }
            report.failures.append(
                TagWriteError(
                    path: journal.directory.path, kind: .journal,
                    detail: "a tag edit was made after Undo Tag Edit asked, so nothing was undone"
                ))
        } catch {
            report.failures.append(error)
        }
        return report
    }

    /// Undoes the newest journaled edit. A file changed since is dropped from the journal with
    /// an error; a file that fails for another reason stays journaled, so undo can try again.
    /// A write in place an earlier call left unfinished is finished first.
    public func undoLast() -> TagWriteReport {
        var report = recoverInterrupted()
        do throws(TagWriteError) {
            let (entry, files, discarded) = try journal.latest()
            report.failures += discarded
            guard let entry else {
                report.nothingToUndo = true
                return report
            }
            var older: [String: (TagUndoJournal.Handle, TagUndoJournal.FileRecord)]?
            let unclear = removeLeftoverTemps(for: files.map(\.1.path), faults)
            for (handle, record) in files.reversed() {
                // Its write in place couldn't be finished; the journal keeps it for the next try.
                guard !journal.isUnconfirmed(handle) else {
                    report.failures.append(
                        TagWriteError(
                            path: record.path, kind: .writeFailed,
                            detail: "its tags were being written in place when that stopped,"
                                + " and it isn't put right yet, so the edit isn't undone"))
                    continue
                }
                let restored: FileIdentity
                do throws(TagWriteError) {
                    if let error = unclear[record.path] { throw error }
                    restored = try restore(record, oldBytes: try journal.oldBytes(handle))
                } catch {
                    logger.error("\(error.description)")
                    report.failures.append(error)
                    if error.kind == .changedSinceEdit { try journal.remove(handle) }
                    continue
                }
                report.changed.append(record.path)
                // The file is back, so what follows is the journal's own bookkeeping. If it
                // fails, a later undo finds the stale record and refuses it as changed since.
                do throws(TagWriteError) {
                    try journal.remove(handle)
                    // The restored file is a new one with the bytes an older edit of it left,
                    // which that edit's record must now name to be undone next.
                    if older == nil { older = try journal.olderRecords(before: entry) }
                    if let (olderHandle, found) = older?[record.path], record.follows(found) {
                        var olderRecord = found
                        olderRecord.setEdited(restored)
                        try journal.update(olderRecord, at: olderHandle)
                    }
                } catch {
                    logger.error("undid \(record.path), but: \(error.description)")
                }
            }
        } catch {
            report.failures.append(error)
        }
        return report
    }

    /// Keep Files Organized renamed each file `from` to `to` (ADR 0164): its undo records
    /// follow it, so Undo Tag Edit finds it at its new path. Returns, for each file, why its
    /// records couldn't follow; its edits then can't be undone.
    public func follow(_ moves: [(from: String, to: String)]) -> [TagWriteError] {
        var failures: [TagWriteError] = []
        var found: [(from: String, to: String, identity: FileIdentity)] = []
        for move in moves {
            do throws(TagWriteError) {
                found.append((move.from, move.to, try identity(move.to)))
            } catch {
                failures.append(error)
            }
        }
        do throws(TagWriteError) {
            try journal.follow(found)
        } catch {
            // The journal stopped partway, so any of these may still name its old path.
            failures += found.map {
                TagWriteError(path: $0.to, kind: error.kind, detail: error.detail)
            }
        }
        for failure in failures { logger.error("\(failure.description)") }
        return failures
    }

    enum Outcome {
        case unchanged
        /// Written and read back as the reader reads it; `problem` is set when its undo record
        /// couldn't be brought up to date.
        case changed(StampedParse, problem: TagWriteError?)
    }

    /// What one file of a batch needs once it's read.
    private enum Prepared {
        /// Left alone, or written through the temp file.
        case done(Outcome)
        /// To be written in place with the rest of its chunk.
        case inPlace(InPlaceJob)
    }

    /// Reads one file and plans its edit. One that fits is checked on its planned file and
    /// handed back to be written in place; any other is written through the temp file now.
    private func prepare(_ edit: TagEdit, _ path: String, entry: TagUndoJournal.Entry)
        throws(TagWriteError) -> Prepared
    {
        let before = try identity(path)
        try requireWritable(path, faults)
        // One open for the tags, the layout, the replaced bytes and the art: on a NAS each open
        // is a few round trips.
        let source: MeteredSource
        let current: ParsedFile
        let file: TagFile
        do throws(MetadataError) {
            (source, current, file) = try opened(path)
        } catch {
            throw TagWriteError(path: path, kind: kind(error.kind), detail: error.description)
        }
        let target: TrackTags
        do throws(TagValueError) {
            target = try edit.applied(to: current.metadata.tags)
        } catch {
            throw TagWriteError(path: path, kind: .invalidValue, detail: error.description)
        }
        let groups = TagGroup.changed(by: edit, from: current.metadata.tags, to: target)
        var art = edit.art == .pictures([]) ? .remove : edit.art
        if art == .remove, current.metadata.art == nil { art = nil }
        guard !groups.isEmpty || art != nil else { return .done(.unchanged) }

        let segments: [Segment]
        do throws(ParseFailure) {
            segments = try file.rewrite(
                groups, from: target, art: art, artOffset: current.metadata.art?.offset)
        } catch {
            throw TagWriteError(path: path, kind: kind(error.kind), detail: error.detail)
        }
        let plan =
            faults.writesInPlace
            ? try InPlacePlan(
                segments, size: before.size, source: source, payload: file.payload, path: path)
            : nil
        var expected = Expected(
            tags: target, audio: current.metadata.audio,
            art: try expectedArt(art, current, source, path))
        if case .pictures(let pictures) = art {
            expected.pictures =
                if case .mp4 = file {
                    mp4CoverOrder(pictures).map { ($0.image, nil) }
                } else {
                    pictures.map { ($0.image, $0.type) }
                }
        }

        if let hook = faults.beforeWritingTemp {
            do {
                try hook(path)
            } catch {
                throw TagWriteError(path: path, kind: .writeFailed, detail: "\(error)")
            }
        }
        if let plan {
            _ = try checkParsed(
                PlannedSource(original: source, plan: plan), original: file, path: path,
                expected: expected
            ) { edited throws(TagWriteError) in
                guard edited.payload == file.payload else {
                    throw TagWriteError(
                        path: path, kind: .checkFailed,
                        detail: "the audio in the new file isn't where the original's is")
                }
            }
            return .inPlace(
                InPlaceJob(
                    path: path, plan: plan, before: before, original: file, expected: expected))
        }
        let (restore, oldBytes) = try restoreSegments(
            segments, from: source, path: path, size: before.size)
        let temp = try writeTemp(
            segments, from: path, identity: before, hashing: file.payload, faults: faults)
        guard let hashes = temp.originalHashes else {
            preconditionFailure("a temp file asked for the hashes has them")
        }
        var handle: TagUndoJournal.Handle?
        var record: TagUndoJournal.FileRecord
        let parsed: ParsedFile
        do throws(TagWriteError) {
            parsed = try checkEdited(
                temp.path, original: file, path: path, hashes: hashes, expected: expected)
            record = TagUndoJournal.FileRecord(
                path: path, edited: try identity(temp.path), original: before,
                originalSHA256: Data(hashes.full), restore: restore)
            handle = try journal.append(record, oldBytes: oldBytes, to: entry)
            try finish(path, temp: temp, before: before)
        } catch {
            // A crash leaves the temp file and the journal as they are.
            if error.detail == crashDetail { throw error }
            unlink(temp.path)
            if let handle {
                do throws(TagWriteError) {
                    try journal.remove(handle)
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
                try journal.update(record, at: handle!)
            }
            // Stamped as the renamed file is, so a rescan that stats it finds the same.
            return .done(.changed(final.stamp(parsed), problem: nil))
        } catch {
            logger.error("\(error.description)")
            return .done(
                .changed(
                    temp.identity.stamp(parsed),
                    problem: TagWriteError(
                        path: path, kind: .journal,
                        detail: "written, but its undo record couldn't be updated: \(error.detail)")
                ))
        }
    }

    /// Finishes each write in place that a crash or a failure left unconfirmed (ADR 0107): a
    /// file that holds the whole new tag keeps it, one that still holds the original is left
    /// alone, and one the write tore is put back from the journal through a temp file. Writes
    /// and undos run this first, and the app at launch.
    public func recoverInterrupted() -> TagWriteReport {
        var report = TagWriteReport()
        do throws(TagWriteError) {
            let (files, discarded) = try journal.unconfirmed()
            for error in discarded { logger.error("\(error.description)") }
            report.failures += discarded
            let unclear = removeLeftoverTemps(for: files.map(\.1.path), faults)
            for (handle, record) in files {
                do throws(TagWriteError) {
                    if let error = unclear[record.path] { throw error }
                    if try recover(record, at: handle) { report.changed.append(record.path) }
                } catch {
                    logger.error("\(error.description)")
                    report.failures.append(error)
                }
            }
        } catch {
            report.failures.append(error)
        }
        return report
    }

    /// Finishes one unconfirmed write in place, and returns whether the file was put back.
    private func recover(_ record: TagUndoJournal.FileRecord, at handle: TagUndoJournal.Handle)
        throws(TagWriteError) -> Bool
    {
        let path = record.path
        var info = stat()
        if lstat(path, &info) != 0, errno == ENOENT {
            try journal.remove(handle)
            throw TagWriteError(
                path: path, kind: .changedSinceEdit,
                detail: "the file whose tags were being written in place is gone")
        }
        let current = try identity(path)
        guard let region = record.inPlace, current.inode == record.originalInode,
            (record.originalSize...max(record.originalSize, region.offset + region.newLength))
                .contains(current.size)
        else {
            try journal.remove(handle)
            throw TagWriteError(
                path: path, kind: .changedSinceEdit,
                detail: "the file was replaced after its tags were being written in place, so"
                    + " that write isn't finished")
        }
        if try regionState(record, region, faults: faults) == .new {
            var landed = record
            landed.setEdited(current)
            try journal.confirm(landed, at: handle)
            logger.notice("the interrupted write in place of \(path) had landed whole; kept")
            return false
        }
        do throws(TagWriteError) {
            return try putBackOriginal(record, at: handle, oldBytes: journal.oldBytes(handle))
        } catch  where error.kind == .checkFailed {
            try journal.remove(handle)
            throw TagWriteError(
                path: path, kind: .changedSinceEdit,
                detail: "its write in place was interrupted, and its journaled bytes don't put"
                    + " it back, so it's left as it is: \(error.detail)")
        }
    }

    /// Puts the original back after a write in place that didn't finish, and drops its
    /// record; returns whether the file had to be rewritten, which it doesn't when its region
    /// still holds the old bytes. The old bytes go back over the region in place, which needs
    /// no free space (ADR 0108); the record and its marker stay until the region reads back as
    /// the old bytes, so a crash part way through is put back again.
    func putBackOriginal(
        _ record: TagUndoJournal.FileRecord, at handle: TagUndoJournal.Handle, oldBytes: [UInt8]
    ) throws(TagWriteError) -> Bool {
        guard let region = record.inPlace else {
            preconditionFailure("only a write in place is put back")
        }
        if try regionState(record, region, faults: faults) == .old {
            // What reads back may be only in the cache, after a put-back cut short before its
            // flush; the record goes only once the old bytes are on the disk.
            try flushDrive(of: record.path, faults: faults)
            try journal.remove(handle)
            logger.notice("\(record.path) still holds its original tags")
            return false
        }
        guard sha256(oldBytes) == region.oldSHA256 else {
            throw TagWriteError(
                path: record.path, kind: .checkFailed,
                detail: "the journaled bytes don't match the hash they were journaled with")
        }
        try overwriteBack(record, region, oldBytes: oldBytes, faults: faults)
        guard try regionState(record, region, faults: faults) == .old else {
            throw TagWriteError(
                path: record.path, kind: .checkFailed,
                detail: "the file doesn't read back as the original's tag bytes")
        }
        let restored = try identity(record.path)
        try journal.remove(handle)
        // As undo does: an older edit of the file now names the restored file.
        if let (olderHandle, found) = try journal.olderRecords(before: handle.entry)[record.path],
            record.follows(found)
        {
            var olderRecord = found
            olderRecord.setEdited(restored)
            try journal.update(olderRecord, at: olderHandle)
        }
        logger.notice("put back \(record.path), whose write in place didn't finish")
        return true
    }

    /// Undoes one journaled file through a temp file, and returns the restored file's identity.
    /// The file must be as the edit left it. The restored file must hash as the original, or for
    /// a write in place have its size and hold the journaled old bytes, which must match their
    /// hash.
    private func restore(_ record: TagUndoJournal.FileRecord, oldBytes: [UInt8])
        throws(TagWriteError) -> FileIdentity
    {
        let path = record.path
        let before = try identity(path)
        guard record.isEdited(before) else {
            throw TagWriteError(
                path: path, kind: .changedSinceEdit,
                detail: "the file changed after the tag edit, so the edit isn't undone")
        }
        if let region = record.inPlace, sha256(oldBytes) != region.oldSHA256 {
            throw TagWriteError(
                path: path, kind: .checkFailed,
                detail: "the journaled bytes don't match the hash they were journaled with")
        }
        try requireWritable(path, faults)
        var cursor = 0
        let segments = record.restore.map { segment -> Segment in
            switch segment {
            case .old(let length):
                defer { cursor += length }
                return .bytes(Array(oldBytes[cursor..<cursor + length]))
            case .edited(let lower, let upper): return .original(lower..<upper)
            }
        }
        let temp = try writeTemp(segments, from: path, identity: before, faults: faults)
        do throws(TagWriteError) {
            if let region = record.inPlace {
                var restored = record
                restored.path = temp.path
                guard try regionState(restored, region, faults: faults) == .old else {
                    throw TagWriteError(
                        path: path, kind: .checkFailed,
                        detail: "the restored file doesn't hold the original's tag bytes")
                }
            } else {
                let restored = try fileHashes(temp.path, payload: [], faults: faults)
                guard Data(restored.full) == record.originalSHA256 else {
                    throw TagWriteError(
                        path: path, kind: .checkFailed,
                        detail: "the restored file doesn't match the original's hash")
                }
            }
            try finish(path, temp: temp, before: before)
        } catch {
            if error.detail != crashDetail { unlink(temp.path) }
            throw error
        }
        logger.notice("undid the tag edit of \(path)")
        return try identity(path)
    }

    /// The last steps: the injected faults, the checks that nothing else wrote the file or
    /// swapped the temp file, then the rename.
    private func finish(_ path: String, temp: TempFile, before: FileIdentity)
        throws(TagWriteError)
    {
        if let hook = faults.beforeReplacing {
            do {
                try hook(path, temp.path)
            } catch {
                throw TagWriteError(path: path, kind: .writeFailed, detail: "\(error)")
            }
        }
        guard try identity(path) == before else {
            throw TagWriteError(path: path, kind: .changedDuringWrite, detail: changedDetail)
        }
        faults.called(.metadata)
        try requireUnchanged(temp, path)
        if faults.crashBeforeRename {
            throw TagWriteError(path: path, kind: .writeFailed, detail: crashDetail)
        }
        try replace(path, with: temp.path, faults)
    }

    /// The file's identity, by `lstat`.
    func identity(_ path: String) throws(TagWriteError) -> FileIdentity {
        faults.called(.metadata)
        return try FileIdentity(path: path)
    }

    /// What a new file must read back as.
    struct Expected {
        var tags: TrackTags
        var audio: TrackAudio
        var art: Data?
        /// Every picture, in the file's order, with its type, nil in MP4; nil when the edit
        /// doesn't set them, and only the art the reader shows is checked.
        var pictures: [(image: Data, type: PictureType?)]?
    }

    /// The art the file must hold after `change`: the new image, none, or what it holds now.
    private func expectedArt(
        _ change: ArtChange?, _ current: ParsedFile, _ source: MeteredSource, _ path: String
    ) throws(TagWriteError) -> Data? {
        switch change {
        case .replace(let image, _): image
        case .pictures(let pictures):
            (pictures.first { $0.type == .frontCover } ?? pictures.first)?.image
        case .remove: nil
        case nil: try currentArt(current, source, path)
        }
    }

    /// Reads the temp file `edited` back with the reader and checks it against what was meant,
    /// its audio payload by hash. Returns what the reader read.
    private func checkEdited(
        _ edited: String, original: TagFile, path: String, hashes: FileHashes,
        expected: Expected
    ) throws(TagWriteError) -> ParsedFile {
        let source: MeteredSource
        do throws(ParseFailure) {
            source = try MeteredSource(path: edited, faults: faults)
        } catch {
            throw TagWriteError(
                path: path, kind: .checkFailed,
                detail: "the new file doesn't read: \(error.error(path: edited).detail)")
        }
        return try checkParsed(source, original: original, path: path, expected: expected) {
            file throws(TagWriteError) in
            let read = try fileHashes(edited, payload: file.payload, faults: faults)
            guard read.payload == hashes.payload else {
                throw TagWriteError(
                    path: path, kind: .checkFailed,
                    detail: "the audio in the new file isn't the same as the original's")
            }
        }
    }

    /// Reads a write in place back from the disk (ADR 0108): its size and the region, through
    /// a new descriptor that doesn't cache, so a network volume answers from the server, against
    /// the bytes written; then the tags, audio format, art and chunk offsets, with the audio
    /// where the original's is. Only the region changed, so nothing else is read whole.
    /// Returns what the reader read.
    func readBack(
        _ plan: InPlacePlan, path: String, original: TagFile, expected: Expected
    ) throws(TagWriteError) -> ParsedFile {
        func failed(_ detail: String) -> TagWriteError {
            TagWriteError(path: path, kind: .checkFailed, detail: detail)
        }
        let source: MeteredSource
        let region: [UInt8]
        do throws(ParseFailure) {
            source = try MeteredSource(path: path, faults: faults)
            region = try source.size == plan.size ? source.read(plan.region) : []
        } catch {
            throw failed("the new file doesn't read: \(error.error(path: path).detail)")
        }
        guard source.size == plan.size else {
            throw failed("the file is \(source.size) bytes after the write, not \(plan.size)")
        }
        guard region == plan.newBytes else {
            throw failed("the file doesn't read back as the bytes written to it")
        }
        return try checkParsed(source, original: original, path: path, expected: expected) {
            edited throws(TagWriteError) in
            guard edited.payload == original.payload else {
                throw failed("the audio in the new file isn't where the original's is")
            }
        }
    }

    /// Reads a new file through `source` and checks its tags, audio format, art and MP4 chunk
    /// offsets against what was meant; `payload` checks its audio, right after the audio's
    /// size. Returns what the reader read.
    private func checkParsed(
        _ source: some ByteSource, original: TagFile, path: String, expected: Expected,
        payload: (TagFile) throws(TagWriteError) -> Void
    ) throws(TagWriteError) -> ParsedFile {
        func failed(_ detail: String) -> TagWriteError {
            TagWriteError(path: path, kind: .checkFailed, detail: detail)
        }
        let edited: TagFile
        let reread: ParsedFile
        do throws(ParseFailure) {
            reread = try parse(ByteReader(source, keepsPictures: expected.pictures != nil))
            edited = try TagFile(ByteReader(source))
        } catch {
            throw failed("the new file doesn't read: \(error.error(path: path).detail)")
        }
        guard edited.payload.map(\.count) == original.payload.map(\.count) else {
            throw failed("the audio in the new file isn't the same as the original's")
        }
        try payload(edited)
        if case .mp4(let new) = edited, case .mp4(let old) = original {
            guard try chunkOffsetsAgree(old, new) else {
                throw failed("the new file's chunk offsets don't point at the same audio")
            }
        }
        guard reread.metadata.audio == expected.audio else {
            throw failed("the new file's audio format reads as \(reread.metadata.audio)")
        }
        guard reread.metadata.tags == expected.tags else {
            throw failed("the tags read back as \(reread.metadata.tags), not \(expected.tags)")
        }
        let newArt = try currentArt(reread, source, path)
        guard newArt == expected.art else {
            throw failed(
                "the art reads back as \(newArt?.count ?? 0) bytes, not \(expected.art?.count ?? 0)"
            )
        }
        if let pictures = expected.pictures {
            let read = reread.metadata.pictures
            guard read.count == pictures.count else {
                throw failed("\(read.count) pictures read back, not \(pictures.count)")
            }
            for (index, (picture, wanted)) in zip(read, pictures).enumerated() {
                let image: Data
                do throws(ParseFailure) {
                    image = try readArt(picture.art, from: source)
                } catch {
                    throw failed("picture \(index + 1) doesn't read: \(error.detail)")
                }
                guard image == wanted.image, picture.type == wanted.type else {
                    throw failed("picture \(index + 1) doesn't read back as the one written")
                }
            }
        }
        return reread
    }

    /// The file at `path` opened once, with its tags as the reader reads them and its layout as
    /// the writer parses it, each through a reader of its own.
    private func opened(_ path: String) throws(MetadataError)
        -> (MeteredSource, ParsedFile, TagFile)
    {
        do throws(ParseFailure) {
            let source = try MeteredSource(path: path, faults: faults)
            return (source, try parse(ByteReader(source)), try TagFile(ByteReader(source)))
        } catch {
            throw error.error(path: path)
        }
    }

    private func currentArt(_ file: ParsedFile, _ source: some ByteSource, _ path: String)
        throws(TagWriteError) -> Data?
    {
        guard let art = file.metadata.art else { return nil }
        do throws(ParseFailure) {
            return try readArt(art, from: source)
        } catch {
            throw TagWriteError(
                path: path, kind: .unreadable, detail: error.error(path: path).description)
        }
    }

    /// The original's bytes that `segments` don't keep, and where the rest went, so the
    /// original can be put back together from the edited file.
    private func restoreSegments(
        _ segments: [Segment], from source: MeteredSource, path: String, size: Int
    ) throws(TagWriteError) -> ([TagUndoJournal.RestoreSegment], [[UInt8]]) {
        var kept: [(original: Range<Int>, edited: Int)] = []
        var offset = 0
        for segment in segments {
            if case .original(let range) = segment { kept.append((range, offset)) }
            offset += segment.count
        }
        kept.sort { $0.original.lowerBound < $1.original.lowerBound }
        var result: [TagUndoJournal.RestoreSegment] = []
        var bytes: [[UInt8]] = []
        var cursor = 0
        func oldBytes(_ range: Range<Int>) throws(TagWriteError) {
            guard !range.isEmpty else { return }
            do throws(ParseFailure) {
                bytes.append(try source.read(range))
                result.append(.old(length: range.count))
            } catch {
                throw TagWriteError(path: path, kind: .unreadable, detail: error.detail)
            }
        }
        for (range, edited) in kept {
            guard range.lowerBound >= cursor else {
                throw TagWriteError(
                    path: path, kind: .checkFailed, detail: "the rewrite keeps a range twice")
            }
            try oldBytes(cursor..<range.lowerBound)
            result.append(.edited(lowerBound: edited, upperBound: edited + range.count))
            cursor = range.upperBound
        }
        try oldBytes(cursor..<size)
        return (result, bytes)
    }
}

/// What one call wrote, left alone and couldn't write.
public struct TagWriteReport: Equatable, Sendable {
    public var changed: [String] = []
    public var unchanged: [String] = []
    public var failures: [TagWriteError] = []
    /// Undo found no journaled edit.
    public var nothingToUndo = false
    /// The files a batch didn't reach because it stopped (a full disk, a broken journal).
    public var notWritten: [String] = []
    /// What the reader read back from each file a write changed, with the file's size and
    /// mtime right after the write, so the library can store it without reading the file
    /// again unless it changed since (ADR 0108). Undo and recovery leave it empty.
    public var parsed: [String: StampedParse] = [:]

    public init() {}
}

let crashDetail = "stopped before the rename, as a crash would"

private func kind(_ kind: MetadataError.Kind) -> TagWriteError.Kind {
    kind == .unreadable ? .unreadable : .unsupported
}

/// Whether every chunk offset in `new` points at the same audio byte as in `old`: the same
/// `mdat`, the same distance into it.
private func chunkOffsetsAgree(_ old: MP4File, _ new: MP4File) throws(TagWriteError) -> Bool {
    func tables(_ file: MP4File) throws(TagWriteError) -> [[Int]] {
        do throws(ParseFailure) {
            return try file.moov.chunkOffsetTables().map { path throws(ParseFailure) in
                try file.moov[path].chunkOffsets()
            }
        } catch {
            throw TagWriteError(path: "", kind: .checkFailed, detail: error.detail)
        }
    }
    func place(_ offset: Int, _ mdats: [Atom]) -> (Int, Int)? {
        mdats.firstIndex { $0.body.contains(offset) }.map {
            ($0, offset - mdats[$0].body.lowerBound)
        }
    }
    let before = try tables(old)
    let after = try tables(new)
    guard before.map(\.count) == after.map(\.count) else { return false }
    for (oldTable, newTable) in zip(before, after) {
        for (a, b) in zip(oldTable, newTable) {
            let oldPlace = place(a, old.mdats)
            let newPlace = place(b, new.mdats)
            if oldPlace == nil, newPlace == nil, a == b { continue }
            guard let oldPlace, let newPlace, oldPlace == newPlace else { return false }
        }
    }
    return true
}
