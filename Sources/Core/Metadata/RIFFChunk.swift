/// A WAV (RIFF) or AIFF (IFF) chunk: a four-character ID, a 32-bit size, the body, and a pad byte
/// when the size is odd.
struct RIFFChunk {
    var id: String
    var start: Int
    var body: Range<Int>
}

/// Calls `body` with each chunk that tiles `range`. Sizes are little-endian in RIFF and big-endian
/// in IFF. A last chunk may omit its pad byte, which many writers do.
func forEachChunk(
    _ reader: ByteReader, in range: Range<Int>, littleEndian: Bool, form: String,
    _ body: (RIFFChunk) throws(ParseFailure) -> Void
) throws(ParseFailure) {
    var offset = range.lowerBound
    while offset < range.upperBound {
        guard range.upperBound - offset >= 8 else {
            throw .malformed(
                at: offset,
                "\(range.upperBound - offset) stray bytes at the end of the \(form) form")
        }
        let header = try reader.bytes(offset..<offset + 8)
        let id = try header.fourCC(0)
        let size = Int(littleEndian ? try header.uint32LE(4) : try header.uint32BE(4))
        guard size <= range.upperBound - offset - 8 else {
            throw .malformed(
                at: offset,
                "\(form) chunk '\(id)' of \(size) bytes runs past the end of the form"
                    + " (\(range.upperBound - offset - 8) bytes left)")
        }
        try body(RIFFChunk(id: id, start: offset, body: offset + 8..<offset + 8 + size))
        offset = min(range.upperBound, offset + 8 + size + (size & 1))
    }
}

/// The ID3v2 tag in an `id3 ` or `ID3 ` chunk, which WAV and AIFF taggers spell either way. Nil
/// for any other chunk.
func id3Chunk(_ reader: ByteReader, _ chunk: RIFFChunk) throws(ParseFailure) -> ID3v2Tag? {
    guard chunk.id == "id3 " || chunk.id == "ID3 " else { return nil }
    return try parseID3v2(
        reader, at: chunk.body.lowerBound, end: chunk.body.upperBound, container: "its chunk")
}
