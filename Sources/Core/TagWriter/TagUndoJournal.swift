import Darwin
import Foundation

/// The last edits' old bytes, so each can be undone byte for byte. Each edit is a folder in
/// `tag-undo` under the app's data directory (or under `--home`'s folder and the tests' temp
/// folders), and each file it changed adds two files there: a small JSON record and the raw
/// bytes the edit replaced. A batch appends per file, so its cost grows with its size, not its
/// square, and every record is on the disk before its music file is replaced.
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

    package let directory: URL
    let capacityBytes: Int

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
    }

    /// One file of an edit: its record and its old bytes, by number in the entry.
    package struct Handle: Equatable, Sendable {
        let entry: Entry
        let number: Int
        var record: URL { entry.folder.appendingPathComponent(name(number) + recordSuffix) }
        var bytes: URL { entry.folder.appendingPathComponent(name(number) + bytesSuffix) }
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
        /// The original's SHA-256, which the restored file must match.
        var originalSHA256: Data
        var restore: [RestoreSegment]

        package init(
            path: String, editedSize: Int, editedModifiedNanoseconds: Int, editedInode: UInt64,
            originalSize: Int, originalModifiedNanoseconds: Int, originalInode: UInt64,
            originalSHA256: Data, restore: [RestoreSegment]
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
        }
    }

    /// How the original is put back together: the next `length` bytes of the record's bytes
    /// file, and ranges of the edited file.
    package enum RestoreSegment: Codable, Equatable, Sendable {
        case old(length: Int)
        case edited(lowerBound: Int, upperBound: Int)
    }

    /// A new, empty edit after the newest one.
    package func newEntry() throws(TagWriteError) -> Entry {
        let sequence = (try sequences(in: directory).last ?? 0) + 1
        let folder = directory.appendingPathComponent(name(sequence))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw journalError("can't make \(folder.path): \(error)")
        }
        try syncFolder(directory.path)
        return Entry(sequence: sequence, folder: folder)
    }

    /// Adds one file to `entry`: its old bytes, then its record, each flushed to the disk, then
    /// the folder, so the record is durable before the music file is replaced.
    package func append(_ record: FileRecord, oldBytes: [[UInt8]], to entry: Entry)
        throws(TagWriteError) -> Handle
    {
        let handle = Handle(entry: entry, number: (try sequences(in: entry.folder).last ?? 0) + 1)
        // F_FULLFSYNC empties the drive's whole cache, so one after both files covers both.
        try writeDurably(oldBytes, to: handle.bytes.path, drive: false)
        try writeDurably([Array(try encode(record))], to: handle.record.path)
        try syncFolder(entry.folder.path)
        return handle
    }

    /// Replaces a file's record, as when the renamed file's mtime or inode differ from the temp
    /// file's.
    package func update(_ record: FileRecord, at handle: Handle) throws(TagWriteError) {
        let staging = handle.record.path + ".new"
        try writeDurably([Array(try encode(record))], to: staging)
        guard rename(staging, handle.record.path) == 0 else {
            throw systemError(handle.record.path, .journal, "can't replace the undo record")
        }
        try syncFolder(handle.entry.folder.path)
    }

    /// Removes one file of an edit, and the edit's folder once it holds none.
    package func remove(_ handle: Handle) throws(TagWriteError) {
        for url in [handle.record, handle.bytes] where unlink(url.path) != 0 && errno != ENOENT {
            throw systemError(url.path, .journal, "can't remove the undo record")
        }
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
        path: String, edited: FileIdentity, original: FileIdentity, originalSHA256: Data,
        restore: [TagUndoJournal.RestoreSegment]
    ) {
        self.init(
            path: path, editedSize: edited.size,
            editedModifiedNanoseconds: edited.modifiedNanoseconds, editedInode: edited.inode,
            originalSize: original.size, originalModifiedNanoseconds: original.modifiedNanoseconds,
            originalInode: original.inode, originalSHA256: originalSHA256, restore: restore)
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
