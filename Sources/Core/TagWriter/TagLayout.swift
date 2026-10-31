/// Where a file keeps its tags and its audio: every block the writer knows, in file order. The
/// corpus survey prints it, and the round trip compares two files' blocks to show an edit left
/// the rest alone.
public struct TagLayout: Equatable, Sendable {
    public enum Container: String, Sendable, CaseIterable {
        case flac, mp4, mp3, wav, aiff
    }

    public var container: Container
    public var blocks: [TagBlock]
    /// The audio's bytes, which an edit must never change. MP4 can have several `mdat`s.
    public var payload: [Range<Int>]
    /// Facts about the layout a writer has to respect, such as "moov after mdat" or "ID3v2.4".
    public var notes: [String]

    /// Bytes the tags can grow into without moving the audio.
    public var paddingBytes: Int {
        blocks.filter { $0.kind == .padding }.reduce(0) { $0 + $1.range.count }
    }
}

public struct TagBlock: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// A container's header or a tag's header, whose sizes change with its contents.
        case header
        /// A tag field: an ID3 frame, an MP4 `ilst` item or a Vorbis comment.
        case field
        case art
        case padding
        /// A block outside the tags that holds no audio, such as `mvhd` or `COMM`.
        case other
        /// MP4 `stco` or `co64`, whose entries move with the audio.
        case chunkOffsets
        case audio
    }

    /// Where the block sits, such as "moov/udta/meta/ilst/©nam" or "ID3/TIT2".
    public var path: String
    public var range: Range<Int>
    public var kind: Kind
    /// The fields whose edit replaces this block. Empty for blocks no edit replaces.
    public var fields: Set<TagEditField>

    init(_ path: String, _ range: Range<Int>, _ kind: Kind, fields: Set<TagEditField> = []) {
        self.path = path
        self.range = range
        self.kind = kind
        self.fields = fields
    }
}

/// How a new file is put together: new bytes and ranges of the file it replaces, in order.
enum Segment: Equatable {
    case bytes([UInt8])
    case original(Range<Int>)

    var count: Int {
        switch self {
        case .bytes(let bytes): bytes.count
        case .original(let range): range.count
        }
    }
}
