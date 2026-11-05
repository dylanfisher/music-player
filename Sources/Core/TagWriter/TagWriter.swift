import Foundation
import Log
import Metadata

private let logger = moduleLogger()

/// The only code that writes music files (AGENTS.md, ADR 0020). Each file is written to a temp
/// file beside it, checked, and renamed over it, so a failure at any step leaves the original
/// as it was. Every edit is journaled so it can be undone.
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
    /// disk or a journal that can't be written, which stop the batch after that file.
    public func write(_ edit: TagEdit, to paths: [String]) -> TagWriteReport {
        var report = TagWriteReport()
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
    public func undoLast() -> TagWriteReport {
        var report = TagWriteReport()
        do throws(TagWriteError) {
            let (entry, files, discarded) = try journal.latest()
            report.failures += discarded
            guard let entry else {
                report.nothingToUndo = true
                return report
            }
            var older: [String: (TagUndoJournal.Handle, TagUndoJournal.FileRecord)]?
            for (handle, record) in files.reversed() {
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
        let before = try FileIdentity(path: path)
        try requireWritable(path)
        // One open for the tags, the layout, the replaced bytes and the art: on a NAS each open
        // is a few round trips.
        let source: FileSource
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
        let hashes = try fileHashes(path, payload: file.payload)
        let (restore, oldBytes) = try restoreSegments(
            segments, from: source, path: path, size: before.size)
        let oldArt = try art == nil ? currentArt(current, source, path) : nil

        if let hook = faults.beforeWritingTemp {
            do {
                try hook(path)
            } catch {
                throw TagWriteError(path: path, kind: .writeFailed, detail: "\(error)")
            }
        }
        let temp = try writeTemp(segments, from: path, identity: before, faults: faults)
        var handle: TagUndoJournal.Handle?
        var record: TagUndoJournal.FileRecord
        do throws(TagWriteError) {
            try checkEdited(
                temp.path, original: file, path: path, hashes: hashes, tags: target,
                audio: current.metadata.audio, art: art, oldArt: oldArt)
            record = TagUndoJournal.FileRecord(
                path: path, edited: try FileIdentity(path: temp.path), original: before,
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
            let final = try FileIdentity(path: path)
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

    /// Puts back the original of one journaled file, and returns the restored file's identity.
    private func restore(_ record: TagUndoJournal.FileRecord, oldBytes: [UInt8])
        throws(TagWriteError) -> FileIdentity
    {
        let path = record.path
        let before = try FileIdentity(path: path)
        guard record.isEdited(before) else {
            throw TagWriteError(
                path: path, kind: .changedSinceEdit,
                detail: "the file changed after the tag edit, so the edit isn't undone")
        }
        try requireWritable(path)
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
            let restored = try fileHashes(temp.path, payload: [])
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
        return try FileIdentity(path: path)
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
        guard try FileIdentity(path: path) == before else {
            throw TagWriteError(
                path: path, kind: .changedDuringWrite,
                detail: "something else changed the file while its tags were written")
        }
        try requireUnchanged(temp, path)
        if faults.crashBeforeRename {
            throw TagWriteError(path: path, kind: .writeFailed, detail: crashDetail)
        }
        try replace(path, with: temp.path)
    }

    /// Reads the edited temp file back with the reader and checks it against what was meant.
    private func checkEdited(
        _ temp: String, original: TagFile, path: String, hashes: FileHashes, tags: TrackTags,
        audio: TrackAudio, art: ArtChange?, oldArt: Data?
    ) throws(TagWriteError) {
        func failed(_ detail: String) -> TagWriteError {
            TagWriteError(path: path, kind: .checkFailed, detail: detail)
        }
        let source: FileSource
        let edited: TagFile
        let reread: ParsedFile
        do throws(MetadataError) {
            (source, reread, edited) = try opened(temp)
        } catch {
            throw failed("the new file doesn't read: \(error.detail)")
        }
        guard edited.payload.map(\.count) == original.payload.map(\.count),
            try fileHashes(temp, payload: edited.payload).payload == hashes.payload
        else { throw failed("the audio in the new file isn't the same as the original's") }
        if case .mp4(let new) = edited, case .mp4(let old) = original {
            guard try chunkOffsetsAgree(old, new) else {
                throw failed("the new file's chunk offsets don't point at the same audio")
            }
        }
        guard reread.metadata.audio == audio else {
            throw failed("the new file's audio format reads as \(reread.metadata.audio)")
        }
        guard reread.metadata.tags == tags else {
            throw failed("the tags read back as \(reread.metadata.tags), not \(tags)")
        }
        let expectedArt: Data? =
            switch art {
            case .replace(let image, _): image
            case .remove: nil
            case nil: oldArt
            }
        let newArt = try currentArt(reread, source, temp)
        guard newArt == expectedArt else {
            throw failed(
                "the art reads back as \(newArt?.count ?? 0) bytes, not \(expectedArt?.count ?? 0)")
        }
    }

    /// The file at `path` opened once, with its tags as the reader reads them and its layout as
    /// the writer parses it, each through a reader of its own.
    private func opened(_ path: String) throws(MetadataError) -> (FileSource, ParsedFile, TagFile) {
        do throws(ParseFailure) {
            let source = try FileSource(path: path)
            return (source, try parse(ByteReader(source)), try TagFile(ByteReader(source)))
        } catch {
            throw error.error(path: path)
        }
    }

    private func currentArt(_ file: ParsedFile, _ source: FileSource, _ path: String)
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
        _ segments: [Segment], from source: FileSource, path: String, size: Int
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

private let crashDetail = "stopped before the rename, as a crash would"

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
