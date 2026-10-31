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
    /// The clock for journal entries.
    let now: @Sendable () -> Date

    public init(journal: TagUndoJournal) {
        self.journal = journal
        now = { Date() }
    }

    /// Writes `edit` into each of `paths`, as one undoable edit. A file the edit changes nothing
    /// in isn't written. Each file's failure is reported and the rest carry on.
    public func write(_ edit: TagEdit, to paths: [String]) -> TagWriteReport {
        var report = TagWriteReport()
        var entry: TagUndoJournal.Entry
        do {
            entry = try journal.newEntry(at: now().timeIntervalSince1970)
        } catch {
            report.failures.append(error)
            return report
        }
        for path in paths {
            // A batch can run over an album of large files; each file's buffers go before the next.
            autoreleasepool {
                do throws(TagWriteError) {
                    if try write(edit, to: path, entry: &entry) {
                        report.changed.append(path)
                    } else {
                        report.unchanged.append(path)
                    }
                } catch {
                    logger.error("\(error.description)")
                    report.failures.append(error)
                }
            }
        }
        return report
    }

    /// Undoes the newest journaled edit. A file changed since is dropped from the journal with
    /// an error; a file that fails for another reason stays journaled, so undo can try again.
    public func undoLast() -> TagWriteReport {
        var report = TagWriteReport()
        do throws(TagWriteError) {
            let (latest, discarded) = try journal.latest()
            report.failures += discarded
            guard var entry = latest else {
                report.nothingToUndo = true
                return report
            }
            var kept: [TagUndoJournal.FileRecord] = []
            for record in entry.files.reversed() {
                do throws(TagWriteError) {
                    try restore(record)
                    report.changed.append(record.path)
                } catch {
                    logger.error("\(error.description)")
                    report.failures.append(error)
                    if error.kind != .changedSinceEdit { kept.insert(record, at: 0) }
                }
            }
            entry.files = kept
            try journal.save(entry)
        } catch {
            report.failures.append(error)
        }
        return report
    }

    /// Writes one file. False when the edit changes nothing in it.
    private func write(_ edit: TagEdit, to path: String, entry: inout TagUndoJournal.Entry)
        throws(TagWriteError) -> Bool
    {
        let before = try FileIdentity(path: path)
        try requireWritable(path)
        let url = URL(fileURLWithPath: path)
        let current: ParsedFile
        let file: TagFile
        do throws(MetadataError) {
            current = try readMetadata(at: url)
            file = try parsed(path)
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
        guard !groups.isEmpty || art != nil else { return false }

        let segments: [Segment]
        do throws(ParseFailure) {
            segments = try file.rewrite(
                groups, from: target, art: art, artOffset: current.metadata.art?.offset)
        } catch {
            throw TagWriteError(path: path, kind: kind(error.kind), detail: error.detail)
        }
        let hashes = try fileHashes(path, payload: file.payload)
        let restore = try restoreSegments(segments, path: path, size: before.size)
        let oldArt = try art == nil ? currentArt(current, url) : nil

        let temp = tempPath(for: path)
        try writeTemp(segments, from: path, to: temp)
        do throws(TagWriteError) {
            try checkEdited(
                temp, original: file, path: path, hashes: hashes, tags: target,
                audio: current.metadata.audio, art: art, oldArt: oldArt)
            let edited = try FileIdentity(path: temp)
            entry.files.append(
                TagUndoJournal.FileRecord(
                    path: path, editedSize: edited.size,
                    editedModifiedNanoseconds: edited.modifiedNanoseconds,
                    originalSHA256: Data(hashes.full), restore: restore))
            try journal.save(entry)
            try finish(path, temp: temp, before: before)
        } catch {
            // A crash leaves the temp file and the journal as they are.
            if error.detail == crashDetail { throw error }
            unlink(temp)
            if entry.files.last?.path == path {
                entry.files.removeLast()
                do throws(TagWriteError) {
                    try journal.save(entry)
                } catch let journalError {
                    logger.error("\(journalError.description)")
                }
            }
            throw error
        }
        logger.notice("wrote tags to \(path)")
        return true
    }

    /// Puts back the original of one journaled file.
    private func restore(_ record: TagUndoJournal.FileRecord) throws(TagWriteError) {
        let path = record.path
        let before = try FileIdentity(path: path)
        guard before.size == record.editedSize,
            before.modifiedNanoseconds == record.editedModifiedNanoseconds
        else {
            throw TagWriteError(
                path: path, kind: .changedSinceEdit,
                detail: "the file changed after the tag edit, so the edit isn't undone")
        }
        try requireWritable(path)
        let temp = tempPath(for: path)
        try writeTemp(record.restore.map(\.segment), from: path, to: temp)
        do throws(TagWriteError) {
            let restored = try fileHashes(temp, payload: [])
            guard restored.full == Array(record.originalSHA256) else {
                throw TagWriteError(
                    path: path, kind: .checkFailed,
                    detail: "the restored file doesn't match the original's hash")
            }
            try finish(path, temp: temp, before: before)
        } catch {
            if error.detail != crashDetail { unlink(temp) }
            throw error
        }
        logger.notice("undid the tag edit of \(path)")
    }

    /// The last steps: the injected faults, the check that nothing else wrote the file, then
    /// the rename.
    private func finish(_ path: String, temp: String, before: FileIdentity) throws(TagWriteError) {
        if let hook = faults.beforeReplacing {
            do {
                try hook(path, temp)
            } catch {
                throw TagWriteError(path: path, kind: .writeFailed, detail: "\(error)")
            }
        }
        guard try FileIdentity(path: path) == before else {
            throw TagWriteError(
                path: path, kind: .changedDuringWrite,
                detail: "something else changed the file while its tags were written")
        }
        if faults.crashBeforeRename {
            throw TagWriteError(path: path, kind: .writeFailed, detail: crashDetail)
        }
        try replace(path, with: temp)
    }

    /// Reads the edited temp file back with the reader and checks it against what was meant.
    private func checkEdited(
        _ temp: String, original: TagFile, path: String, hashes: FileHashes, tags: TrackTags,
        audio: TrackAudio, art: ArtChange?, oldArt: Data?
    ) throws(TagWriteError) {
        func failed(_ detail: String) -> TagWriteError {
            TagWriteError(path: path, kind: .checkFailed, detail: detail)
        }
        let url = URL(fileURLWithPath: temp)
        let edited: TagFile
        let reread: ParsedFile
        do throws(MetadataError) {
            edited = try parsed(temp)
            reread = try readMetadata(at: url)
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
        let newArt = try currentArt(reread, url)
        guard newArt == expectedArt else {
            throw failed(
                "the art reads back as \(newArt?.count ?? 0) bytes, not \(expectedArt?.count ?? 0)")
        }
    }

    private func parsed(_ path: String) throws(MetadataError) -> TagFile {
        do throws(ParseFailure) {
            return try TagFile(path: path)
        } catch {
            throw error.error(path: path)
        }
    }

    private func currentArt(_ file: ParsedFile, _ url: URL) throws(TagWriteError) -> Data? {
        guard let art = file.metadata.art else { return nil }
        do throws(MetadataError) {
            return try readArt(art, at: url)
        } catch {
            throw TagWriteError(path: url.path, kind: .unreadable, detail: error.description)
        }
    }

    /// The original's bytes that `segments` don't keep, and where the rest went, so the
    /// original can be put back together from the edited file.
    private func restoreSegments(_ segments: [Segment], path: String, size: Int)
        throws(TagWriteError) -> [TagUndoJournal.RestoreSegment]
    {
        var kept: [(original: Range<Int>, edited: Int)] = []
        var offset = 0
        for segment in segments {
            if case .original(let range) = segment { kept.append((range, offset)) }
            offset += segment.count
        }
        kept.sort { $0.original.lowerBound < $1.original.lowerBound }
        var result: [TagUndoJournal.RestoreSegment] = []
        var cursor = 0
        let source: FileSource
        do throws(ParseFailure) {
            source = try FileSource(path: path)
        } catch {
            throw TagWriteError(path: path, kind: .unreadable, detail: error.detail)
        }
        func oldBytes(_ range: Range<Int>) throws(TagWriteError) {
            guard !range.isEmpty else { return }
            do throws(ParseFailure) {
                result.append(.bytes(Data(try source.read(range))))
            } catch {
                throw TagWriteError(path: path, kind: .unreadable, detail: error.detail)
            }
        }
        for (range, edited) in kept {
            precondition(range.lowerBound >= cursor, "kept ranges overlap")
            try oldBytes(cursor..<range.lowerBound)
            result.append(.edited(lowerBound: edited, upperBound: edited + range.count))
            cursor = range.upperBound
        }
        try oldBytes(cursor..<size)
        return result
    }
}

/// What one call wrote, left alone and couldn't write.
public struct TagWriteReport: Equatable, Sendable {
    public var changed: [String] = []
    public var unchanged: [String] = []
    public var failures: [TagWriteError] = []
    /// Undo found no journaled edit.
    public var nothingToUndo = false

    public init() {}
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
