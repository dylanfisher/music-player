/// Why one file's tags weren't written or restored. The file is as it was before the attempt.
public struct TagWriteError: Error, Equatable, CustomStringConvertible {
    public enum Kind: String, Sendable {
        /// The file couldn't be opened or read.
        case unreadable
        /// A layout or feature the writer doesn't rewrite, such as ID3v2.2 or a fragmented MP4.
        case unsupported
        /// A value the edit can't write.
        case invalidValue
        /// The file or its folder can't be written, or the file is locked.
        case notWritable
        /// Something else changed the file while it was being written.
        case changedDuringWrite
        /// The new file didn't read back as it should: audio, tags, art or chunk offsets.
        case checkFailed
        /// Writing or replacing failed, as when the disk is full.
        case writeFailed
        /// The file changed after the edit, so undoing it would lose that change.
        case changedSinceEdit
        /// The undo journal couldn't be read or saved. A batch stops here.
        case journal
        /// The disk the file or the journal is on is full. A batch stops here.
        case diskFull
    }

    public var path: String
    public var kind: Kind
    public var detail: String

    init(path: String, kind: Kind, detail: String) {
        self.path = path
        self.kind = kind
        self.detail = detail
    }

    public var description: String { "\(path): \(detail)" }

    /// Whether the rest of a batch would fail the same way, so it stops after this file.
    var stopsBatch: Bool { kind == .journal || kind == .diskFull }
}
