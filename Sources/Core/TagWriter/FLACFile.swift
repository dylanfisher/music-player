import Foundation
import Log
import Metadata

/// A FLAC file's metadata blocks, in memory, before audio frames that are left in the file.
struct FLACFile {
    enum BlockType: UInt8 {
        case streamInfo = 0
        case padding = 1
        case vorbisComment = 4
        case picture = 6
    }

    struct Block {
        var type: UInt8
        var body: [UInt8]
        /// Where the block, header included, was in the file.
        var original: Range<Int>?
    }

    /// The most a block's 24-bit length holds.
    static let maximumBlockBytes = 1 << 24 - 1
    static let marker = Array(flacMarker.utf8)

    var size: Int
    var blocks: [Block]
    /// Where the audio frames start.
    var audioStart: Int

    init(_ reader: ByteReader) throws(ParseFailure) {
        size = reader.size
        var offset = Self.marker.count
        var blocks: [Block] = []
        var isLast = false
        while !isLast {
            let header = try reader.bytes(offset..<offset + 4)
            isLast = try header.uint8(0) & 0x80 != 0
            let end = offset + 4 + Int(try header.uint24BE(1))
            guard end <= reader.size else {
                throw .malformed(at: offset, "FLAC metadata block runs past the end of the file")
            }
            blocks.append(
                Block(
                    type: try header.uint8(0) & 0x7F,
                    body: try reader.bytes(offset + 4..<end).array, original: offset..<end))
            offset = end
        }
        self.blocks = blocks
        audioStart = offset
    }

    var metadataByteCount: Int { blocks.reduce(0) { $0 + 4 + $1.body.count } }

    func rewrite(
        _ groups: [TagGroup], from tags: TrackTags, art: ArtChange?, artOffset: Int?
    ) throws(ParseFailure) -> [Segment] {
        var blocks = self.blocks
        if let art { apply(art, to: &blocks, artOffset: artOffset) }
        if !groups.isEmpty {
            var index = blocks.firstIndex { $0.type == BlockType.vorbisComment.rawValue }
            if index == nil {
                blocks.insert(
                    Block(type: BlockType.vorbisComment.rawValue, body: emptyVorbisComment()),
                    at: 1)
                index = 1
            }
            blocks[index!].body = try editedComments(blocks[index!].body, groups, tags)
        }
        for block in blocks where block.body.count > Self.maximumBlockBytes {
            throw .unsupported(at: nil, "a FLAC metadata block over 16 MB")
        }

        let oldBytes = metadataByteCount
        var delta = blocks.reduce(0) { $0 + 4 + $1.body.count } - oldBytes
        if delta != 0,
            let padding = blocks.lastIndex(where: { $0.type == BlockType.padding.rawValue })
        {
            let available = blocks[padding].body.count
            if available >= delta {
                blocks[padding].body = zeros(available - delta)
                delta = 0
            } else if available + 4 == delta {
                blocks.remove(at: padding)
                delta = 0
            }
        }
        if delta < -4 {
            blocks.append(Block(type: BlockType.padding.rawValue, body: zeros(-delta - 4)))
            delta = 0
        }
        if delta != 0 {
            let tagBytes = blocks.filter { $0.type != BlockType.padding.rawValue }
                .reduce(0) { $0 + 4 + $1.body.count }
            let room = zeros(min(rewritePaddingBytes(tagBytes: tagBytes), Self.maximumBlockBytes))
            if let padding = blocks.lastIndex(where: { $0.type == BlockType.padding.rawValue }) {
                blocks[padding].body = room
            } else {
                blocks.append(Block(type: BlockType.padding.rawValue, body: room))
            }
        }
        var bytes = Self.marker
        for (index, block) in blocks.enumerated() {
            bytes.append(block.type | (index == blocks.count - 1 ? 0x80 : 0))
            bytes += bigEndianBytes(block.body.count, 3)
            bytes += block.body
        }
        return [.bytes(bytes), .original(audioStart..<size)]
    }

    private func apply(_ art: ArtChange, to blocks: inout [Block], artOffset: Int?) {
        let picture = BlockType.picture.rawValue
        switch art {
        case .remove:
            blocks.removeAll { $0.type == picture }
        case .replace(let image, let mimeType):
            var body = bigEndianBytes(Int(frontCoverPictureType), 4)
            body += bigEndianBytes(mimeType.utf8.count, 4) + Array(mimeType.utf8)
            // No description; width, height, depth and colors unknown, which FLAC allows as 0.
            body += zeros(4) + zeros(16) + bigEndianBytes(image.count, 4) + Array(image)
            let new = Block(type: picture, body: body)
            if let index = blocks.firstIndex(where: { block in
                block.type == picture
                    && artOffset.map { block.original?.contains($0) == true } == true
            }) {
                blocks[index] = new
            } else {
                blocks.append(new)
            }
        }
    }

    /// The vendor and every comment the edit doesn't replace, byte for byte; the replaced
    /// group's new comments go where its first old one was.
    private func editedComments(_ body: [UInt8], _ groups: [TagGroup], _ tags: TrackTags)
        throws(ParseFailure) -> [UInt8]
    {
        let (vendor, comments) = try vorbisComments(body, base: 0)
        var kept = comments.map(\.raw)
        for group in groups {
            let keys =
                group.customKey.map { [$0] }
                ?? Set(group.readerFields.flatMap { vorbisKeys(for: $0) })
            let isReplaced = { (raw: [UInt8]) in keys.contains(vorbisKey(raw)) }
            let first = kept.firstIndex(where: isReplaced)
            kept.removeAll(where: isReplaced)
            let new = vorbisValues(group, tags).map { Array("\($0.key)=\($0.value)".utf8) }
            kept.insert(contentsOf: new, at: min(first ?? kept.count, kept.count))
        }
        var result = littleEndianBytes(vendor.count, 4) + vendor + littleEndianBytes(kept.count, 4)
        for comment in kept { result += littleEndianBytes(comment.count, 4) + comment }
        return result
    }

    private func vorbisValues(_ group: TagGroup, _ tags: TrackTags) -> [(
        key: String, value: String
    )] {
        if let name = group.customName { return group.text(in: tags).map { [(name, $0)] } ?? [] }
        let keys = group.readerFields.map { field in
            guard let key = vorbisWrittenKey(for: field) else {
                preconditionFailure("\(field) has no Vorbis key")
            }
            return key
        }
        guard group.isPair else { return group.text(in: tags).map { [(keys[0], $0)] } ?? [] }
        let (number, total) = group.numbers(in: tags)
        return [number.map { (keys[0], "\($0)") }, total.map { (keys[1], "\($0)") }]
            .compactMap { $0 }
    }

    private func emptyVorbisComment() -> [UInt8] {
        let vendor = Array(appDirectoryName.utf8)
        return littleEndianBytes(vendor.count, 4) + vendor + littleEndianBytes(0, 4)
    }

    // MARK: Layout

    func layout() throws(ParseFailure) -> TagLayout {
        var blocks = [TagBlock(flacMarker, 0..<4, .header)]
        for block in self.blocks {
            let range = block.original!
            let name = BlockType(rawValue: block.type).map { "\($0)" } ?? "block\(block.type)"
            // The header's last-block flag changes when blocks are added; the body is what must
            // stay.
            blocks.append(
                TagBlock("\(name)/header", range.lowerBound..<range.lowerBound + 4, .header))
            let body = range.lowerBound + 4..<range.upperBound
            switch BlockType(rawValue: block.type) {
            case .padding: blocks.append(TagBlock(name, body, .padding))
            case .picture: blocks.append(TagBlock(name, body, .art))
            case .vorbisComment:
                let (vendor, comments) = try vorbisComments(block.body, base: body.lowerBound)
                let count = body.lowerBound + 4 + vendor.count
                blocks.append(TagBlock("\(name)/vendor", body.lowerBound..<count, .other))
                blocks.append(TagBlock("\(name)/count", count..<count + 4, .header))
                for comment in comments {
                    let key = vorbisKey(comment.raw)
                    blocks.append(
                        TagBlock("\(name)/\(key)", comment.range, .field, group: vorbisGroup(key)))
                }
            case .streamInfo, nil:
                blocks.append(TagBlock(name, body, .other))
            }
        }
        blocks.append(TagBlock(audioFramesPath, audioStart..<size, .audio))
        return TagLayout(container: .flac, blocks: blocks, payload: [audioStart..<size], notes: [])
    }
}

/// The vendor's bytes, and each comment's bytes with its file range, length included.
func vorbisComments(_ body: [UInt8], base: Int) throws(ParseFailure)
    -> (vendor: [UInt8], comments: [(raw: [UInt8], range: Range<Int>)])
{
    let block = Bytes(body, base: base)
    let vendorLength = Int(try block.uint32LE(0))
    let vendor = try block.slice(4..<4 + vendorLength).array
    var cursor = 4 + vendorLength
    let count = Int(try block.uint32LE(cursor))
    cursor += 4
    guard count <= (block.count - cursor) / 4 else {
        throw .malformed(at: base + cursor - 4, "Vorbis comment count \(count) is too large")
    }
    var comments: [(raw: [UInt8], range: Range<Int>)] = []
    for _ in 0..<count {
        let length = Int(try block.uint32LE(cursor))
        let raw = try block.slice(cursor + 4..<cursor + 4 + length).array
        comments.append((raw, base + cursor..<base + cursor + 4 + length))
        cursor += 4 + length
    }
    return (vendor, comments)
}

/// A comment's key, uppercased as the reader compares it.
func vorbisKey(_ raw: [UInt8]) -> String {
    latin1(raw.prefix { $0 != UInt8(ascii: "=") }).uppercased()
}

/// The group whose edit replaces a comment of `key`, uppercased: a field's, else the custom
/// key's.
func vorbisGroup(_ key: String) -> TagGroup? {
    TagGroup.of(matching: { vorbisKeys(for: $0).contains(key) }) ?? TagGroup.custom(named: key)
}
