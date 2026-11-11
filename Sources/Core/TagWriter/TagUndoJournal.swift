import Darwin
import Foundation

/// The last edits' old bytes, so each can be undone byte for byte. Each edit is a folder in
/// `tag-undo` under the app's data directory (or under `--home`'s folder and the tests' temp
/// folders), and each file it changed adds two files there: a small JSON record and the raw
/// bytes the edit replaced. A batch appends per file, so its cost grows with its size, not its
/// square, and every record is on the disk before its music file is replaced or overwritten.
/// A file written in place also gets a marker in `tag-undo` itself until its write is
/// confirmed, so the writer finds an interrupted one without reading every record (ADR 0107);
/// the marker alone says the write is unconfirmed (ADR 0108).
public struct TagUndoJournal: Sendable {
    /// Edits kept; older ones are dropped once a new one is written.
    package static let capacity = 50
    /// The bytes the kept edits may take by default; older ones are dropped past it. The newest
    /// edit is kept whatever its size, so it can always be undone.
    static let defaultCapacityBytes = 512 * 1024 * 1024
    static let folderName = "tag-undo"
    /// Entry folders and record files are numbers, zero-padded so they sort by name.
    fileprivate static let sequenceDigits = 8
    package static let recordSuffix = ".json"
    package static let bytesSuffix = ".bytes"
    static let unconfirmedSuffix = ".unconfirmed"

    package let directory: URL
    let capacityBytes: Int
    /// Told of each flush through the drive's cache, for the tests to count.
    var driveFlushed: (@Sendable () -> Void)?

    public init(dataDirectory: URL) {
        self.init(dataDirectory: dataDirectory, capacityBytes: Self.defaultCapacityBytes)
    }

    package init(dataDirectory: URL, capacityBytes: Int) {
        directory = dataDirectory.appendingPathComponent(Self.folderName)
        self.capacityBytes = capacityBytes
    }

    /// One edit's folder.
    package struct Entry: Equatable, Sendable {
        let sequence: Int
        let folder: URL
        /// Which window made the edit, written with its folder; nil for an entry read back,
        /// whose origin `newestEdit` reads from the folder.
        var origin: TagEditOrigin?
        var originFile: URL { folder.appendingPathComponent(originName) }
    }

    /// The file in an edit's folder that names its origin, which the listing of records skips.
    static let originName = "origin"

    /// One file of an edit: its record and its old bytes, by number in the entry.
    package struct Handle: Equatable, Sendable {
        let entry: Entry
        let number: Int
        var record: URL { entry.folder.appendingPathComponent(name(number) + recordSuffix) }
        var bytes: URL { entry.folder.appendingPathComponent(name(number) + bytesSuffix) }
        /// `<entry>.<number>.unconfirmed` beside the entry folders, which the listing of
        /// entries skips.
        var marker: URL {
            entry.folder.deletingLastPathComponent().appendingPathComponent(
                entry.folder.lastPathComponent + "." + name(number) + unconfirmedSuffix)
        }
    }

    package struct FileRecord: Codable, Equatable, Sendable {
        var path: String
        /// The edited file as it was right after the rename. Undo refuses a file that no
        /// longer matches.
        var editedSize: Int
        var editedModifiedNanoseconds: Int
        var editedInode: UInt64
        /// The file as it was before the edit. When it's what an older edit of the file left,
        /// undoing this edit hands that edit the restored file, so it can be undone next.
        var originalSize: Int
        var originalModifiedNanoseconds: Int
        var originalInode: UInt64
        /// A write through the temp file's: the original's SHA-256, which the restored file
        /// must match. Nil for a write in place, which `inPlace` checks instead.
        var originalSHA256: Data?
        var restore: [RestoreSegment]
        /// A write in place's: the bytes it changes and what they hold before and after
        /// (ADR 0108). Until the write is confirmed the edited identity is the original's.
        var inPlace: InPlaceRegion?

        package init(
            path: String, editedSize: Int, editedModifiedNanoseconds: Int, editedInode: UInt64,
            originalSize: Int, originalModifiedNanoseconds: Int, originalInode: UInt64,
            originalSHA256: Data?, restore: [RestoreSegment], inPlace: InPlaceRegion? = nil
        ) {
            self.path = path
            self.editedSize = editedSize
            self.editedModifiedNanoseconds = editedModifiedNanoseconds
            self.editedInode = editedInode
            self.originalSize = originalSize
            self.originalModifiedNanoseconds = originalModifiedNanoseconds
            self.originalInode = originalInode
            self.originalSHA256 = originalSHA256
            self.restore = restore
            self.inPlace = inPlace
        }
    }

    /// Where a write in place goes and what it finds there: the old bytes, which the record's
    /// bytes file holds, before the write, and the new bytes after. Recovery and undo check
    /// these instead of hashing the whole file, since the write touches nothing else.
    package struct InPlaceRegion: Codable, Equatable, Sendable {
        var offset: Int
        var oldSHA256: Data
        /// More than the old bytes' length when the file grows at its end, as an MP4 with
        /// `moov` last does.
        var newLength: Int
        var newSHA256: Data
    }

    /// How the original is put back together: the next `length` bytes of the record's bytes
    /// file, and ranges of the edited file.
    package enum RestoreSegment: Codable, Equatable, Sendable {
        case old(length: Int)
        case edited(lowerBound: Int, upperBound: Int)
    }

    /// A new, empty edit after the newest one, made by `origin`.
    package func newEntry(origin: TagEditOrigin = .tagEditor) throws(TagWriteError) -> Entry {
        let sequence = (try sequences(in: directory).last ?? 0) + 1
        let entry = Entry(
            sequence: sequence, folder: directory.appendingPathComponent(name(sequence)),
            origin: origin)
        try makeFolder(of: entry)
        return entry
    }

    /// The newest edit, who made it and how many files it holds, without changing the journal;
    /// nil for an empty journal. The origin is nil for an edit whose folder doesn't name one.
    func newestEdit() throws(TagWriteError) -> JournaledEdit? {
        for sequence in try sequences(in: directory).reversed() {
            let entry = Entry(
                sequence: sequence, folder: directory.appendingPathComponent(name(sequence)))
            let count = try sequences(in: entry.folder).count
            guard count > 0 else { continue }
            guard FileManager.default.fileExists(atPath: entry.originFile.path) else {
                return JournaledEdit(sequence: sequence, origin: nil, fileCount: count)
            }
            do {
                let named = try String(contentsOf: entry.originFile, encoding: .utf8)
                // One this build doesn't know is discarded, as stored data has one shape.
                return JournaledEdit(
                    sequence: sequence, origin: TagEditOrigin(rawValue: named), fileCount: count)
            } catch {
                throw journalError("can't read \(entry.originFile.path): \(error)")
            }
        }
        return nil
    }

    /// Makes `entry`'s folder if it isn't there: removing an edit's last file removes its
    /// folder, and a batch whose first files fail goes on adding to the same edit.
    private func makeFolder(of entry: Entry) throws(TagWriteError) {
        guard !FileManager.default.fileExists(atPath: entry.folder.path) else { return }
        do {
            try FileManager.default.createDirectory(
                at: entry.folder, withIntermediateDirectories: true)
            try entry.origin.map { try Data($0.rawValue.utf8).write(to: entry.originFile) }
        } catch {
            throw journalError("can't make \(entry.folder.path): \(error)")
        }
        try syncFolder(directory.path)
    }

    /// Adds one file to `entry`: its old bytes and its record, each flushed with its folder, then
    /// the drive's cache, so all of it is durable before the music file is replaced.
    package func append(_ record: FileRecord, oldBytes: [[UInt8]], to entry: Entry)
        throws(TagWriteError) -> Handle
    {
        try makeFolder(of: entry)
        let handle = Handle(entry: entry, number: (try sequences(in: entry.folder).last ?? 0) + 1)
        try writeDurably(oldBytes, to: handle.bytes.path, drive: false)
        try writeDurably([Array(try encode(record))], to: handle.record.path, drive: false)
        try syncFolder(entry.folder.path)
        // F_FULLFSYNC empties the drive's whole cache, which may reach the disk in any order,
        // so one after the files and their folders covers them all.
        try flushDrive(directory.path)
        return handle
    }

    /// Adds the files of a batch written in place to `entry` (ADR 0108): each one's old bytes,
    /// record and marker flushed with `fsync`, then their folders, then the drive's cache once,
    /// so all of it is durable before any of the music files is written. A failure part way
    /// takes out what was added.
    func appendInPlace(_ files: [(record: FileRecord, oldBytes: [UInt8])], to entry: Entry)
        throws(TagWriteError) -> [Handle]
    {
        try makeFolder(of: entry)
        let first = (try sequences(in: entry.folder).last ?? 0) + 1
        var handles: [Handle] = []
        do throws(TagWriteError) {
            for (offset, file) in files.enumerated() {
                let handle = Handle(entry: entry, number: first + offset)
                handles.append(handle)
                try writeDurably([file.oldBytes], to: handle.bytes.path, drive: false)
                try writeDurably(
                    [Array(try encode(file.record))], to: handle.record.path, drive: false)
                try writeDurably([], to: handle.marker.path, drive: false)
            }
            try syncFolder(entry.folder.path)
            try syncFolder(directory.path)
            try flushDrive(directory.path)
        } catch {
            var detail = error.detail
            for handle in handles {
                do throws(TagWriteError) {
                    try remove(handle)
                } catch let removing {
                    detail += "; and \(removing.detail)"
                }
            }
            throw TagWriteError(path: error.path, kind: error.kind, detail: detail)
        }
        return handles
    }

    /// Records that a write in place landed and read back: `record` is saved with the file's
    /// identity, then the marker goes, neither through the drive's cache (ADR 0108). If a power
    /// cut keeps the marker, recovery finds the new bytes and confirms the record again; if it
    /// keeps the marker's removal and loses the record, undo finds the file changed since and
    /// leaves it as it is.
    func confirm(_ record: FileRecord, at handle: Handle) throws(TagWriteError) {
        try update(record, at: handle, drive: false)
        try removeMarker(handle)
    }

    /// Whether the write in place `handle` records is still unconfirmed: its marker is there.
    func isUnconfirmed(_ handle: Handle) -> Bool {
        FileManager.default.fileExists(atPath: handle.marker.path)
    }

    /// The records whose write in place a crash or a failure left unconfirmed, found by their
    /// markers. A marker whose record is gone or isn't a write in place is removed; a record
    /// that doesn't read is deleted and reported, as `latest` does.
    func unconfirmed() throws(TagWriteError)
        -> (files: [(Handle, FileRecord)], discarded: [TagWriteError])
    {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch CocoaError.fileReadNoSuchFile {
            return ([], [])
        } catch {
            throw journalError("can't list \(directory.path): \(error)")
        }
        var files: [(Handle, FileRecord)] = []
        var discarded: [TagWriteError] = []
        for marker in names.sorted() where marker.hasSuffix(Self.unconfirmedSuffix) {
            let parts = marker.dropLast(Self.unconfirmedSuffix.count).split(separator: ".")
            guard parts.count == 2, parts.allSatisfy({ $0.count == Self.sequenceDigits }),
                let sequence = Int(parts[0]), let number = Int(parts[1])
            else { continue }
            let entry = Entry(
                sequence: sequence, folder: directory.appendingPathComponent(String(parts[0])))
            let handle = Handle(entry: entry, number: number)
            guard FileManager.default.fileExists(atPath: handle.record.path) else {
                try removeMarker(handle)
                continue
            }
            let record: FileRecord
            do {
                record = try decodeExactly(FileRecord.self, from: Data(contentsOf: handle.record))
            } catch {
                discarded.append(
                    journalError("discarded \(handle.record.path), which doesn't read: \(error)"))
                try remove(handle)
                continue
            }
            if record.inPlace == nil {
                try removeMarker(handle)
            } else {
                files.append((handle, record))
            }
        }
        return (files, discarded)
    }

    private func removeMarker(_ handle: Handle) throws(TagWriteError) {
        guard unlink(handle.marker.path) == 0 || errno == ENOENT else {
            throw systemError(handle.marker.path, .journal, "can't remove the marker")
        }
        try syncFolder(directory.path)
    }

    /// Replaces a file's record, as when the renamed file's mtime or inode differ from the temp
    /// file's.
    package func update(_ record: FileRecord, at handle: Handle, drive: Bool = true)
        throws(TagWriteError)
    {
        let staging = handle.record.path + ".new"
        try writeDurably([Array(try encode(record))], to: staging, drive: false)
        guard rename(staging, handle.record.path) == 0 else {
            throw systemError(handle.record.path, .journal, "can't replace the undo record")
        }
        try syncFolder(handle.entry.folder.path)
        // After the rename, so the drive can't keep a later change and lose this one.
        if drive { try flushDrive(handle.entry.folder.path) }
    }

    /// Empties the drive's cache through `path`'s volume, so what was flushed to the drive
    /// before survives a power cut.
    private func flushDrive(_ path: String) throws(TagWriteError) {
        driveFlushed?()
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw systemError(path, .journal, "can't open the folder") }
        defer { close(descriptor) }
        try flush(descriptor, path, .journal)
    }

    /// Removes one file of an edit, its marker if it has one, and the edit's folder once it
    /// holds none.
    package func remove(_ handle: Handle) throws(TagWriteError) {
        for url in [handle.record, handle.bytes] where unlink(url.path) != 0 && errno != ENOENT {
            throw systemError(url.path, .journal, "can't remove the undo record")
        }
        if FileManager.default.fileExists(atPath: handle.marker.path) { try removeMarker(handle) }
        try removeIfEmpty(handle.entry)
    }

    func removeIfEmpty(_ entry: Entry) throws(TagWriteError) {
        guard FileManager.default.fileExists(atPath: entry.folder.path),
            try sequences(in: entry.folder).isEmpty
        else { return }
        do {
            try FileManager.default.removeItem(at: entry.folder)
        } catch {
            throw journalError("can't remove \(entry.folder.path): \(error)")
        }
    }

    /// The newest edit's files, in the order they were written, with nil for an empty journal.
    /// A record that doesn't decode exactly, or whose bytes file doesn't match it, is deleted
    /// and reported, since stored data has one shape (AGENTS.md).
    package func latest() throws(TagWriteError)
        -> (entry: Entry?, files: [(Handle, FileRecord)], discarded: [TagWriteError])
    {
        var discarded: [TagWriteError] = []
        for sequence in try sequences(in: directory).reversed() {
            let entry = Entry(
                sequence: sequence, folder: directory.appendingPathComponent(name(sequence)))
            var files: [(Handle, FileRecord)] = []
            for number in try sequences(in: entry.folder) {
                let handle = Handle(entry: entry, number: number)
                do {
                    let record = try decodeExactly(
                        FileRecord.self, from: Data(contentsOf: handle.record))
                    let size = try handle.bytes.resourceValues(forKeys: [.fileSizeKey]).fileSize
                    guard size == record.oldByteCount else {
                        throw DecodingError.dataCorrupted(
                            .init(codingPath: [], debugDescription: "its bytes file doesn't match"))
                    }
                    files.append((handle, record))
                } catch {
                    discarded.append(
                        journalError(
                            "discarded \(handle.record.path), which doesn't read: \(error)"))
                    try remove(handle)
                }
            }
            if !files.isEmpty { return (entry, files, discarded) }
            try removeIfEmpty(entry)
        }
        return (nil, [], discarded)
    }

    /// The newest record of each path among the edits older than `entry`. A record that doesn't
    /// read is left out; `latest` reports and deletes it when undo reaches its edit.
    func olderRecords(before entry: Entry) throws(TagWriteError) -> [String: (Handle, FileRecord)] {
        var records: [String: (Handle, FileRecord)] = [:]
        for sequence in try sequences(in: directory).reversed() where sequence < entry.sequence {
            let older = Entry(
                sequence: sequence, folder: directory.appendingPathComponent(name(sequence)))
            for number in try sequences(in: older.folder).reversed() {
                let handle = Handle(entry: older, number: number)
                // A record that doesn't read is reported by `latest`, as the doc comment says.
                guard
                    let record = try? decodeExactly(
                        FileRecord.self, from: Data(contentsOf: handle.record)),
                    records[record.path] == nil
                else { continue }
                records[record.path] = (handle, record)
            }
        }
        return records
    }

    /// Points every record of each moved file, in every edit kept, at its new path, where Keep
    /// Files Organized renamed it (ADR 0164), so undo finds it there and an older edit still
    /// follows a newer one: one pass over the records and one flush through the drive for all
    /// of `moves`. A record whose edited size and mtime are its file's `identity` takes that
    /// identity too, since a rename changes neither but a share may give the file a new inode.
    /// That is the newest record of the file: an older one's edited identity is compared only
    /// with the newer record's original one, which was taken before the move as well, so it
    /// keeps the old inode, and undoing the newer edit hands it the restored file's. A record
    /// that doesn't read is left alone; `latest` reports and deletes it when undo reaches its
    /// edit.
    func follow(_ moves: [(from: String, to: String, identity: FileIdentity)])
        throws(TagWriteError)
    {
        let byPath = Dictionary(
            moves.map { ($0.from.precomposedStringWithCanonicalMapping, $0) },
            uniquingKeysWith: { one, _ in one })
        guard !byPath.isEmpty else { return }
        var changed = false
        for sequence in try sequences(in: directory) {
            let entry = Entry(
                sequence: sequence, folder: directory.appendingPathComponent(name(sequence)))
            for number in try sequences(in: entry.folder) {
                let handle = Handle(entry: entry, number: number)
                // A record that doesn't read is left alone; `latest` reports it.
                guard
                    var record = try? decodeExactly(
                        FileRecord.self, from: Data(contentsOf: handle.record)),
                    let move = byPath[record.path.precomposedStringWithCanonicalMapping]
                else { continue }
                record.path = move.to
                if record.editedSize == move.identity.size,
                    record.editedModifiedNanoseconds == move.identity.modifiedNanoseconds
                {
                    record.setEdited(move.identity)
                }
                try update(record, at: handle, drive: false)
                changed = true
            }
        }
        if changed { try flushDrive(directory.path) }
    }

    /// The old bytes of one file, as `RestoreSegment.old` consumes them.
    func oldBytes(_ handle: Handle) throws(TagWriteError) -> [UInt8] {
        do {
            return Array(try Data(contentsOf: handle.bytes))
        } catch {
            throw journalError("can't read \(handle.bytes.path): \(error)")
        }
    }

    /// Drops the oldest edits past `capacity`, then past `capacityBytes`, keeping the newest.
    func prune() throws(TagWriteError) {
        var sequences = try sequences(in: directory)
        var sizes = try sequences.map { sequence throws(TagWriteError) in
            try folderBytes(directory.appendingPathComponent(name(sequence)))
        }
        while sequences.count > 1,
            sequences.count > Self.capacity || sizes.reduce(0, +) > capacityBytes
        {
            let folder = directory.appendingPathComponent(name(sequences.removeFirst()))
            sizes.removeFirst()
            do {
                try FileManager.default.removeItem(at: folder)
            } catch {
                throw journalError("can't drop the old edit \(folder.path): \(error)")
            }
        }
    }

    private func folderBytes(_ folder: URL) throws(TagWriteError) -> Int {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.fileSizeKey]
            ).reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        } catch {
            throw journalError("can't measure \(folder.path): \(error)")
        }
    }

    /// The numbered entries in `folder`: entry folders, or record files. Anything else is left
    /// alone.
    private func sequences(in folder: URL) throws(TagWriteError) -> [Int] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: folder.path)
                .compactMap { name -> Int? in
                    let stem =
                        folder == directory
                        ? Substring(name)
                        : name.hasSuffix(Self.recordSuffix)
                            ? name.dropLast(Self.recordSuffix.count) : ""
                    guard stem.count == Self.sequenceDigits else { return nil }
                    return Int(stem)
                }
                .sorted()
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            throw journalError("can't list \(folder.path): \(error)")
        }
    }

    private func encode(_ record: FileRecord) throws(TagWriteError) -> Data {
        do {
            return try encoder().encode(record)
        } catch {
            throw journalError("can't encode the undo record of \(record.path): \(error)")
        }
    }

    private func journalError(_ detail: String) -> TagWriteError {
        TagWriteError(path: directory.path, kind: .journal, detail: detail)
    }
}

extension TagUndoJournal.FileRecord {
    init(
        path: String, edited: FileIdentity, original: FileIdentity, originalSHA256: Data?,
        restore: [TagUndoJournal.RestoreSegment], inPlace: TagUndoJournal.InPlaceRegion? = nil
    ) {
        self.init(
            path: path, editedSize: edited.size,
            editedModifiedNanoseconds: edited.modifiedNanoseconds, editedInode: edited.inode,
            originalSize: original.size, originalModifiedNanoseconds: original.modifiedNanoseconds,
            originalInode: original.inode, originalSHA256: originalSHA256, restore: restore,
            inPlace: inPlace)
    }

    /// Records `identity` as the edited file's.
    mutating func setEdited(_ identity: FileIdentity) {
        editedSize = identity.size
        editedModifiedNanoseconds = identity.modifiedNanoseconds
        editedInode = identity.inode
    }

    /// Whether `identity` is the file as this edit left it.
    func isEdited(_ identity: FileIdentity) -> Bool {
        identity.size == editedSize && identity.modifiedNanoseconds == editedModifiedNanoseconds
            && identity.inode == editedInode
    }

    /// Whether the file this edit started from is the one `older` left.
    func follows(_ older: Self) -> Bool {
        originalSize == older.editedSize
            && originalModifiedNanoseconds == older.editedModifiedNanoseconds
            && originalInode == older.editedInode
    }

    var oldByteCount: Int {
        restore.reduce(0) { total, segment in
            if case .old(let length) = segment { total + length } else { total }
        }
    }
}

private func name(_ number: Int) -> String {
    let digits = String(number)
    return String(repeating: "0", count: max(0, TagUndoJournal.sequenceDigits - digits.count))
        + digits
}

/// Writes `chunks` to a new file at `path` and flushes it to the disk before returning: to the
/// drive's own cache with `fsync`, and through it too unless `drive` is false.
private func writeDurably(_ chunks: [[UInt8]], to path: String, drive: Bool = true)
    throws(TagWriteError)
{
    let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw systemError(path, .journal, "can't create") }
    defer { close(descriptor) }
    for chunk in chunks {
        var done = 0
        while done < chunk.count {
            let count = chunk.withUnsafeBytes {
                write(descriptor, $0.baseAddress! + done, chunk.count - done)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw systemError(path, .journal, "can't write")
            }
            done += count
        }
    }
    if drive {
        try flush(descriptor, path, .journal)
    } else if fsync(descriptor) != 0 {
        throw systemError(path, .journal, "can't flush it")
    }
}

/// Flushes a folder's entries, so a file just made or renamed in it survives a power cut.
func syncFolder(_ path: String) throws(TagWriteError) {
    let descriptor = open(path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw systemError(path, .journal, "can't open the folder") }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else {
        throw systemError(path, .journal, "can't flush the folder")
    }
}

/// `F_FULLFSYNC` reaches the disk itself; volumes without it (SMB) take `fsync`.
func flush(_ descriptor: Int32, _ path: String, _ kind: TagWriteError.Kind) throws(TagWriteError) {
    if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 {
        throw systemError(path, kind, "can't flush it to the disk")
    }
}

private func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}

/// Decodes `T` and fails unless encoding it again gives the same JSON, so an unknown or
/// misspelled key anywhere in the file is an error rather than ignored.
func decodeExactly<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
    let value = try JSONDecoder().decode(type, from: data)
    let read = try JSONSerialization.jsonObject(with: data) as? NSObject
    let written = try JSONSerialization.jsonObject(with: encoder().encode(value)) as? NSObject
    guard let read, let written, read.isEqual(written) else {
        throw DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "it holds keys or values \(type) doesn't"))
    }
    return value
}
