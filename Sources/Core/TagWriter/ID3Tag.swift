import Metadata

/// An ID3v2.3 or 2.4 tag split into frames, each kept as the bytes it was read as, so frames an
/// edit doesn't name are written back byte for byte, in their order.
struct ID3Tag {
    static let headerBytes = 10
    /// What a rewritten tag leaves free for later edits, so most of them fit in place.
    static let rewritePaddingBytes = 2048

    var version: UInt8
    var flags: UInt8
    var frames: [ID3Frame]
    /// Header, frames and padding, as the tag occupies its file.
    var byteCount: Int
    /// The tag's file offset.
    var start: Int

    /// A new, empty ID3v2.4 tag, for a file that has none.
    init(newAt start: Int) {
        version = 4
        flags = 0
        frames = []
        byteCount = 0
        self.start = start
    }

    /// Parses `bytes`, the whole tag read from file offset `start`. 2.2, unsynchronised tags,
    /// extended headers and footers are refused: rewriting them right means more than their
    /// frames.
    init(_ bytes: [UInt8], at start: Int) throws(ParseFailure) {
        let tag = Bytes(bytes, base: start)
        guard tag.count >= Self.headerBytes, tag.matches(id3v2Identifier, at: 0) else {
            throw .malformed(at: start, "no ID3v2 header")
        }
        version = try tag.uint8(3)
        flags = try tag.uint8(5)
        self.start = start
        guard version == 3 || version == 4 else {
            throw .unsupported(at: start, "writing ID3v2.\(version) tags")
        }
        guard flags & 0xD0 == 0 else {
            throw .unsupported(
                at: start + 5,
                "writing an ID3v2 tag that's unsynchronised or has an extended header or footer")
        }
        guard let size = try tag.syncsafe(6), Self.headerBytes + size <= tag.count else {
            throw .malformed(at: start + 6, "ID3v2 tag size doesn't fit the bytes read")
        }
        byteCount = Self.headerBytes + size
        frames = []
        var cursor = Self.headerBytes
        while byteCount - cursor >= ID3Frame.headerBytes {
            if try tag.uint8(cursor) == 0 { break }
            let id = latin1(try tag.slice(cursor..<cursor + 4).array)
            guard id.utf8.allSatisfy({ (0x41...0x5A).contains($0) || (0x30...0x39).contains($0) })
            else {
                throw .unsupported(
                    at: start + cursor,
                    "ID3v2 frame ID \"\(id)\" is invalid, so the frames after it can't be found")
            }
            let size = try frameSize(tag, at: cursor, end: byteCount)
            let end = cursor + ID3Frame.headerBytes + size
            guard end <= byteCount else {
                throw .malformed(at: start + cursor, "ID3v2 frame \(id) runs past its tag")
            }
            frames.append(ID3Frame(id: id, raw: try tag.slice(cursor..<end).array))
            cursor = end
        }
    }

    /// 2.3 sizes are plain; 2.4 sizes are syncsafe, but older iTunes wrote plain ones, so the
    /// reading that lands on the next frame, padding or the end wins, as in the reader.
    private func frameSize(_ tag: Bytes, at cursor: Int, end: Int) throws(ParseFailure) -> Int {
        let plain = Int(try tag.uint32BE(cursor + 4))
        guard version == 4 else { return plain }
        let syncsafe = try tag.syncsafe(cursor + 4)
        func lands(_ size: Int) throws(ParseFailure) -> Bool {
            let next = cursor + ID3Frame.headerBytes + size
            guard next < end else { return next == end }
            if try tag.uint8(next) == 0 { return true }
            guard end - next >= 4 else { return false }
            return try tag.slice(next..<next + 4).array.allSatisfy {
                (0x41...0x5A).contains($0) || (0x30...0x39).contains($0)
            }
        }
        if let syncsafe {
            if syncsafe == plain { return syncsafe }
            if try lands(syncsafe) { return syncsafe }
        }
        if try lands(plain) { return plain }
        guard let syncsafe else {
            throw .malformed(at: start + cursor + 4, "ID3v2.4 frame size isn't syncsafe")
        }
        return syncsafe
    }

    var framesByteCount: Int { frames.reduce(0) { $0 + $1.raw.count } }

    /// The tag in `byteCount` bytes, with the frames' leftover space as padding; nil when the
    /// frames don't fit. Throws for a tag past ID3's 256 MB.
    func serialized(byteCount total: Int) throws(ParseFailure) -> [UInt8]? {
        let body = total - Self.headerBytes
        guard body >= framesByteCount else { return nil }
        var bytes = Array(id3v2Identifier.utf8) + [version, 0, flags] + (try syncsafeBytes(body))
        bytes.reserveCapacity(total)
        for frame in frames { bytes += frame.raw }
        bytes += [UInt8](repeating: 0, count: total - bytes.count)
        return bytes
    }

    /// The tag in its own space if the frames fit there, otherwise with fresh padding.
    func rewritten() throws(ParseFailure) -> [UInt8] {
        if byteCount > 0, let bytes = try serialized(byteCount: byteCount) { return bytes }
        let total = Self.headerBytes + framesByteCount + Self.rewritePaddingBytes
        guard let bytes = try serialized(byteCount: total) else {
            throw .malformed(at: start, "an ID3 tag sized for its frames doesn't hold them")
        }
        return bytes
    }

    /// Replaces every frame `isReplaced` picks with `new`, placed where the first of them was,
    /// or after the last frame.
    mutating func replace(where isReplaced: (ID3Frame) -> Bool, with new: [ID3Frame]) {
        let first = frames.firstIndex(where: isReplaced)
        frames.removeAll(where: isReplaced)
        let position = first.map { min($0, frames.count) } ?? frames.count
        frames.insert(contentsOf: new, at: position)
    }

    /// The tag's blocks, with frame offsets in the file.
    func blocks(prefix: String) -> [TagBlock] {
        var blocks = [TagBlock(prefix, start..<start + Self.headerBytes, .header)]
        var cursor = start + Self.headerBytes
        for frame in frames {
            let range = cursor..<cursor + frame.raw.count
            if id3PictureFrameIDs.contains(frame.id) {
                blocks.append(TagBlock("\(prefix)/\(frame.id)", range, .art))
            } else {
                blocks.append(
                    TagBlock(
                        "\(prefix)/\(frame.id)", range, .field, fields: id3Fields(of: frame)))
            }
            cursor = range.upperBound
        }
        if cursor < start + byteCount {
            blocks.append(TagBlock("\(prefix)/padding", cursor..<start + byteCount, .padding))
        }
        return blocks
    }

    /// The fields an edit replaces this frame for. A described comment is a player's own data.
    private func id3Fields(of frame: ID3Frame) -> Set<TagEditField> {
        guard
            let group = TagGroup.allCases.first(where: { group in
                group.readerFields.contains { id3FrameIDs(for: $0).contains(frame.id) }
            })
        else { return [] }
        if group == .comment, !frame.isUserComment(version: version) { return [] }
        return Set(group.fields)
    }
}

/// One frame: its 10-byte header and its body, as read or as made.
struct ID3Frame: Equatable {
    static let headerBytes = 10

    var id: String
    var raw: [UInt8]

    init(id: String, raw: [UInt8]) {
        self.id = id
        self.raw = raw
    }

    /// A frame with no flags set, its size written the way `version` reads it. Throws for a body
    /// past ID3's 256 MB.
    init(id: String, body: [UInt8], version: UInt8) throws(ParseFailure) {
        self.id = id
        let size = try syncsafeBytes(body.count)
        raw =
            Array(id.utf8) + (version == 4 ? size : bigEndianBytes(body.count, 4)) + [0, 0] + body
    }

    var body: ArraySlice<UInt8> { raw[Self.headerBytes...] }

    /// A `COMM` frame whose description is empty, which the reader takes as the comment.
    /// Frames whose format flags change their body (2.3: compressed, encrypted, grouped; 2.4:
    /// grouped, compressed, encrypted, unsynchronised, with a length) aren't looked into, so
    /// they never count.
    func isUserComment(version: UInt8) -> Bool {
        let bodyFlags: UInt8 = version == 3 ? 0xE0 : 0x4F
        guard id3FrameIDs(for: .comment).contains(id), raw[9] & bodyFlags == 0 else {
            return false
        }
        let body = Array(self.body)
        guard body.count >= 4 else { return false }
        let wide = body[0] == 1 || body[0] == 2
        let terminator: [UInt8] = wide ? [0, 0] : [0]
        var index = 4
        while index + terminator.count <= body.count {
            if Array(body[index..<index + terminator.count]) == terminator {
                let description = body[4..<index]
                return description.isEmpty || description.elementsEqual([0xFF, 0xFE])
                    || description.elementsEqual([0xFE, 0xFF])
            }
            index += terminator.count
        }
        return false
    }
}

/// 28 bits, seven per byte: ID3's sizes, up to 256 MB.
func syncsafeBytes(_ value: Int) throws(ParseFailure) -> [UInt8] {
    guard value >= 0, value < 1 << 28 else {
        throw .unsupported(
            at: nil, "\(value) bytes in one ID3 tag or frame; ID3 holds at most 256 MB")
    }
    return [21, 14, 7, 0].map { UInt8(value >> $0 & 0x7F) }
}

func bigEndianBytes(_ value: Int, _ count: Int) -> [UInt8] {
    (0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
}

func littleEndianBytes(_ value: Int, _ count: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
}
