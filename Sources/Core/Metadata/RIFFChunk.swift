/// A WAV (RIFF) or AIFF (IFF) chunk: a four-character ID, a 32-bit size, the body, and a pad byte
/// when the size is odd.
package struct RIFFChunk {
    package var id: String
    package var start: Int
    package var body: Range<Int>
    /// The size the header states, which exceeds `body.count` for a clamped audio chunk.
    var declaredSize: Int
}

/// A streamed writer that couldn't know the size leaves all ones.
private let streamedSize = 0xFFFF_FFFF

/// Where the form ends: its declared end, clamped to the file. A form that claims more than the
/// file holds is a truncated download, not damage to the structure, so it warns. A streamed size
/// reads to the end of the file without a warning.
package func formEnd(_ reader: ByteReader, size: Int, form: String) throws(ParseFailure) -> Int {
    guard size >= 4 else {
        throw .malformed(at: 4, "\(form) size \(size) is too short for its form type")
    }
    // One missing pad byte on the last chunk is common and isn't truncation.
    if size != streamedSize, 8 + size > reader.size + 1 {
        reader.warn(
            .truncated, at: 4,
            "\(form) size \(size) doesn't fit the file (\(reader.size) bytes); read what is there")
    }
    return min(8 + size, reader.size)
}

/// Calls `body` with each chunk that tiles `range`. Sizes are little-endian in RIFF and big-endian
/// in IFF. A last chunk may omit its pad byte, which many writers do. The chunk `audioID` names
/// is the audio body: one that runs past the end is clamped to it, with a warning unless the form
/// already warned or the size is the streamed one.
package func forEachChunk(
    _ reader: ByteReader, in range: Range<Int>, littleEndian: Bool, form: String,
    audioID: String? = nil,
    _ body: (RIFFChunk) throws(ParseFailure) -> Void
) throws(ParseFailure) {
    var offset = range.lowerBound
    while offset < range.upperBound {
        try reader.step(at: offset)
        guard range.upperBound - offset >= 8 else {
            throw .malformed(
                at: offset,
                "\(range.upperBound - offset) stray bytes at the end of the \(form) form")
        }
        let header = try reader.bytes(offset..<offset + 8)
        let id = try header.fourCC(0)
        let size = Int(littleEndian ? try header.uint32LE(4) : try header.uint32BE(4))
        if size > range.upperBound - offset - 8, id == audioID {
            if size != streamedSize, !reader.warnings.contains(where: { $0.kind == .truncated }) {
                reader.warn(
                    .truncated, at: offset,
                    "\(form) chunk '\(id)' of \(size) bytes runs past the end of the file;"
                        + " read what is there")
            }
            try body(
                RIFFChunk(
                    id: id, start: offset, body: offset + 8..<range.upperBound, declaredSize: size))
            return
        }
        guard size <= range.upperBound - offset - 8 else {
            throw .malformed(
                at: offset,
                "\(form) chunk '\(id)' of \(size) bytes runs past the end of the form"
                    + " (\(range.upperBound - offset - 8) bytes left)")
        }
        try body(
            RIFFChunk(
                id: id, start: offset, body: offset + 8..<offset + 8 + size,
                declaredSize: size))
        offset = min(range.upperBound, offset + 8 + size + (size & 1))
    }
}

/// The ID3 chunk's ID as WAV and AIFF taggers usually spell it; the reader takes either in both.
package let wavID3ChunkID = "id3 "
package let aiffID3ChunkID = "ID3 "

/// The ID3v2 tag in an `id3 ` or `ID3 ` chunk, which WAV and AIFF taggers spell either way. Nil
/// for any other chunk.
func id3Chunk(_ reader: ByteReader, _ chunk: RIFFChunk) throws(ParseFailure) -> ID3v2Tag? {
    guard chunk.id == wavID3ChunkID || chunk.id == aiffID3ChunkID else { return nil }
    return try parseID3v2(
        reader, at: chunk.body.lowerBound, end: chunk.body.upperBound, container: "its chunk")
}
