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
    public func write(_ edit: TagEdit, to paths: [String]) -> TagWriteReport {
        var report = recoverInterrupted()
        let entry: TagUndoJournal.Entry
        do {
            entry = try journal.newEntry()
        } catch {
            report.failures.append(error)
            report.notWritten = paths
            return report
        }
        for (index, path) in paths.enumerated() {
            // A batch can run over an album of large files; each file's buffers go before the next.
            let stop = autoreleasepool { () -> Bool in
                do throws(TagWriteError) {
                    switch try write(edit, to: path, entry: entry) {
                    case .unchanged: report.unchanged.append(path)
                    case .changed(let problem):
                        report.changed.append(path)
                        if let problem { report.failures.append(problem) }
                    }
                    return false
                } catch {
                    logger.error("\(error.description)")
                    report.failures.append(error)
                    return error.stopsBatch
                }
            }
            if stop {
                report.notWritten = Array(paths[(index + 1)...])
                if !report.notWritten.isEmpty {
                    logger.error(
                        "stopped the batch; \(report.notWritten.count) files weren't written")
                }
                break
            }
        }
        do throws(TagWriteError) {
            try journal.removeIfEmpty(entry)
            try journal.prune()
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
            for (handle, record) in files.reversed() {
                // Its write in place couldn't be finished; the journal keeps it for the next try.
                guard record.unconfirmedSHA256 == nil else {
                    report.failures.append(
                        TagWriteError(
                            path: record.path, kind: .writeFailed,
                            detail: "its tags were being written in place when that stopped,"
                                + " and it isn't put right yet, so the edit isn't undone"))
                    continue
                }
                let restored: FileIdentity
                do throws(TagWriteError) {
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

    private enum Outcome {
        case unchanged
        /// Written; `problem` is set when its undo record couldn't be brought up to date.
        case changed(problem: TagWriteError?)
    }

    /// Writes one file.
    private func write(_ edit: TagEdit, to path: String, entry: TagUndoJournal.Entry)
        throws(TagWriteError) -> Outcome
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
        let art = edit.art == .remove && current.metadata.art == nil ? nil : edit.art
        guard !groups.isEmpty || art != nil else { return .unchanged }

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
        let hashes = try fileHashes(
            path, payload: file.payload, faults: faults,
            replacing: plan.map { ($0.offset, $0.newBytes) })
        let expected = Expected(
            tags: target, audio: current.metadata.audio,
            art: try expectedArt(art, current, source, path))

        if let hook = faults.beforeWritingTemp {
            do {
                try hook(path)
            } catch {
                throw TagWriteError(path: path, kind: .writeFailed, detail: "\(error)")
            }
        }
        if let plan {
            return try writeInPlace(
                plan, path: path, before: before, source: source, original: file,
                hashes: hashes, expected: expected, entry: entry)
        }
        let (restore, oldBytes) = try restoreSegments(
            segments, from: source, path: path, size: before.size)
        let temp = try writeTemp(segments, from: path, identity: before, faults: faults)
        var handle: TagUndoJournal.Handle?
        var record: TagUndoJournal.FileRecord
        do throws(TagWriteError) {
            _ = try checkEdited(
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
            return .changed(problem: nil)
        } catch {
            logger.error("\(error.description)")
            return .changed(
                problem: TagWriteError(
                    path: path, kind: .journal,
                    detail: "written, but its undo record couldn't be updated: \(error.detail)"))
        }
    }

    /// Writes one file's new tags over its old ones in place (ADR 0107). The plan is read back
    /// from the file as it would be before a byte is written; the old bytes are journaled and
    /// flushed before the original is touched; the file is read back after. A failure once the
    /// write has started puts the original back from the journal.
    private func writeInPlace(
        _ plan: InPlacePlan, path: String, before: FileIdentity, source: MeteredSource,
        original: TagFile, hashes: FileHashes, expected: Expected, entry: TagUndoJournal.Entry
    ) throws(TagWriteError) -> Outcome {
        _ = try checkParsed(
            PlannedSource(original: source, plan: plan), original: original, path: path,
            expected: expected
        ) { edited throws(TagWriteError) in
            guard edited.payload == original.payload else {
                throw TagWriteError(
                    path: path, kind: .checkFailed,
                    detail: "the audio in the new file isn't where the original's is")
            }
        }
        try removeLeftoverTemps(for: path, faults)
        var record = TagUndoJournal.FileRecord(
            path: path, edited: before, original: before, originalSHA256: Data(hashes.full),
            restore: plan.restore(size: before.size),
            unconfirmedSHA256: hashes.edited.map(Data.init))
        let handle = try journal.append(record, oldBytes: [plan.oldBytes], to: entry)
        var wrote = false
        do throws(TagWriteError) {
            if let hook = faults.beforeReplacing {
                do {
                    try hook(path, nil)
                } catch {
                    throw TagWriteError(path: path, kind: .writeFailed, detail: "\(error)")
                }
            }
            try overwrite(path, with: plan, identity: before, faults: faults, wrote: &wrote)
            if let hook = faults.afterOverwriting {
                do {
                    try hook(path)
                } catch {
                    throw TagWriteError(path: path, kind: .writeFailed, detail: "\(error)")
                }
            }
            let readBack = try checkEdited(
                path, original: original, path: path, hashes: hashes, expected: expected)
            guard readBack.full == hashes.edited else {
                throw TagWriteError(
                    path: path, kind: .checkFailed,
                    detail: "the file doesn't read back as the bytes written to it")
            }
        } catch {
            // A crash leaves the file and the journal as they are, for recovery to finish.
            if error.detail == crashDetail { throw error }
            guard wrote else {
                do throws(TagWriteError) {
                    try journal.remove(handle)
                } catch let journalError {
                    logger.error("\(journalError.description)")
                }
                throw error
            }
            logger.error("\(error.description)")
            do throws(TagWriteError) {
                _ = try putBackOriginal(record, at: handle, oldBytes: plan.oldBytes)
            } catch let putBack {
                logger.error("\(putBack.description)")
                throw TagWriteError(
                    path: path, kind: error.kind,
                    detail: "\(error.detail); the original isn't put back yet, and the next"
                        + " write or undo tries again: \(putBack.detail)")
            }
            throw error
        }
        logger.notice("wrote tags in place to \(path)")
        do throws(TagWriteError) {
            record.setEdited(try identity(path))
            try journal.confirm(record, at: handle)
            return .changed(problem: nil)
        } catch {
            logger.error("\(error.description)")
            return .changed(
                problem: TagWriteError(
                    path: path, kind: .journal,
                    detail: "written, but its undo record couldn't be confirmed: \(error.detail)"))
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
            for (handle, record) in files {
                do throws(TagWriteError) {
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
        guard current.inode == record.originalInode, current.size == record.originalSize else {
            try journal.remove(handle)
            throw TagWriteError(
                path: path, kind: .changedSinceEdit,
                detail: "the file was replaced after its tags were being written in place, so"
                    + " that write isn't finished")
        }
        if Data(try fileHashes(path, payload: [], faults: faults).full) == record.unconfirmedSHA256
        {
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
                detail: "its write in place was interrupted, and it changed outside its tags"
                    + " since, so it's left as it is: \(error.detail)")
        }
    }

    /// Puts the original back after a write in place that didn't finish, and drops its
    /// record; returns whether the file had to be rewritten, which it doesn't when it already
    /// hashes as the original.
    private func putBackOriginal(
        _ record: TagUndoJournal.FileRecord, at handle: TagUndoJournal.Handle, oldBytes: [UInt8]
    ) throws(TagWriteError) -> Bool {
        if Data(try fileHashes(record.path, payload: [], faults: faults).full)
            == record.originalSHA256
        {
            try journal.remove(handle)
            logger.notice("\(record.path) still holds its original tags")
            return false
        }
        let restored = try restore(record, oldBytes: oldBytes, requireEdited: false)
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

    /// Puts back the original of one journaled file, and returns the restored file's identity.
    /// The file must be as the edit left it unless `requireEdited` is false, as for a write in
    /// place that didn't finish; the restored file must hash as the original either way.
    private func restore(
        _ record: TagUndoJournal.FileRecord, oldBytes: [UInt8], requireEdited: Bool = true
    ) throws(TagWriteError) -> FileIdentity {
        let path = record.path
        let before = try identity(path)
        guard !requireEdited || record.isEdited(before) else {
            throw TagWriteError(
                path: path, kind: .changedSinceEdit,
                detail: "the file changed after the tag edit, so the edit isn't undone")
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
            let restored = try fileHashes(temp.path, payload: [], faults: faults)
            guard restored.full == Array(record.originalSHA256) else {
                throw TagWriteError(
                    path: path, kind: .checkFailed,
                    detail: "the restored file doesn't match the original's hash")
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
    private func identity(_ path: String) throws(TagWriteError) -> FileIdentity {
        faults.called(.metadata)
        return try FileIdentity(path: path)
    }

    /// What a new file must read back as.
    private struct Expected {
        var tags: TrackTags
        var audio: TrackAudio
        var art: Data?
    }

    /// The art the file must hold after `change`: the new image, none, or what it holds now.
    private func expectedArt(
        _ change: ArtChange?, _ current: ParsedFile, _ source: MeteredSource, _ path: String
    ) throws(TagWriteError) -> Data? {
        switch change {
        case .replace(let image, _): image
        case .remove: nil
        case nil: try currentArt(current, source, path)
        }
    }

    /// Reads the edited file `edited` (a temp file, or the original once written in place)
    /// back with the reader and checks it against what was meant, its audio payload by hash.
    /// Returns its hashes, from the one pass that read it whole.
    private func checkEdited(
        _ edited: String, original: TagFile, path: String, hashes: FileHashes,
        expected: Expected
    ) throws(TagWriteError) -> FileHashes {
        let source: MeteredSource
        do throws(ParseFailure) {
            source = try MeteredSource(path: edited, faults: faults)
        } catch {
            throw TagWriteError(
                path: path, kind: .checkFailed,
                detail: "the new file doesn't read: \(error.error(path: edited).detail)")
        }
        var readBack: FileHashes?
        _ = try checkParsed(source, original: original, path: path, expected: expected) {
            file throws(TagWriteError) in
            let read = try fileHashes(edited, payload: file.payload, faults: faults)
            guard read.payload == hashes.payload else {
                throw TagWriteError(
                    path: path, kind: .checkFailed,
                    detail: "the audio in the new file isn't the same as the original's")
            }
            readBack = read
        }
        return readBack!
    }

    /// Reads a new file through `source` and checks its tags, audio format, art and MP4 chunk
    /// offsets against what was meant; `payload` checks its audio, right after the audio's
    /// size. Returns the new file's layout.
    private func checkParsed(
        _ source: some ByteSource, original: TagFile, path: String, expected: Expected,
        payload: (TagFile) throws(TagWriteError) -> Void
    ) throws(TagWriteError) -> TagFile {
        func failed(_ detail: String) -> TagWriteError {
            TagWriteError(path: path, kind: .checkFailed, detail: detail)
        }
        let edited: TagFile
        let reread: ParsedFile
        do throws(ParseFailure) {
            reread = try parse(ByteReader(source))
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
        return edited
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

    init() {}
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
