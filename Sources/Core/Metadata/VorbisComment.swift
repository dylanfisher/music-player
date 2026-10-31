/// Vorbis comment keys, compared uppercased, and the fields they set. Several taggers' spellings
/// of the same field are listed.
private let vorbisFields: [String: TagField] = [
    "TITLE": .title, "ARTIST": .artist, "ALBUM": .album, "ALBUMARTIST": .albumArtist,
    "ALBUM ARTIST": .albumArtist, "GENRE": .genre, "DATE": .date, "TRACKNUMBER": .track,
    "TRACKTOTAL": .trackTotal, "TOTALTRACKS": .trackTotal, "DISCNUMBER": .disc,
    "DISCTOTAL": .discTotal, "TOTALDISCS": .discTotal, "COMPILATION": .compilation,
    "COMPOSER": .composer, "COMMENT": .comment, "DESCRIPTION": .comment,
]

/// The keys, uppercased, that the reader maps onto `field`, so a writer replaces exactly those.
package func vorbisKeys(for field: TagField) -> Set<String> {
    Set(vorbisFields.compactMap { key, each in each == field ? key : nil })
}

/// Little-endian lengths, unlike the rest of FLAC: the vendor string, the comment count, then each
/// comment as `KEY=value` in UTF-8. Unknown keys are skipped; they're the user's own fields.
func parseVorbisComment(_ block: Bytes, _ reader: ByteReader) throws(ParseFailure) -> TrackTags {
    var tags = TrackTags()
    var cursor = 4 + Int(try block.uint32LE(0))
    let count = Int(try block.uint32LE(cursor))
    cursor += 4
    // Each comment takes at least its 4-byte length, so a larger count can't be real.
    guard count <= (block.count - cursor) / 4 else {
        throw .malformed(
            at: block.fileOffset(cursor - 4),
            "Vorbis comment count \(count) doesn't fit in its \(block.count)-byte block")
    }
    for _ in 0..<count {
        let length = Int(try block.uint32LE(cursor))
        guard length <= block.count - cursor - 4 else {
            throw .malformed(
                at: block.fileOffset(cursor),
                "Vorbis comment of \(length) bytes runs past the end of its block")
        }
        let comment = try block.slice(cursor + 4..<cursor + 4 + length)
        let offset = block.fileOffset(cursor)
        cursor += 4 + length
        let bytes = comment.array
        guard let equals = bytes.firstIndex(of: UInt8(ascii: "=")) else {
            reader.warn(.unreadableField, at: offset, "Vorbis comment without \"=\"; skipped")
            continue
        }
        let key = latin1(bytes[..<equals]).uppercased()
        guard let field = vorbisFields[key] else { continue }
        let text = TextEncoding.utf8.decode(
            Array(bytes[(equals + 1)...]), at: offset, warnings: &reader.warnings)
        tags.set(field, text, at: offset, warnings: &reader.warnings)
    }
    return tags
}
