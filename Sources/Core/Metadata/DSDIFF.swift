let dffFormID = "FRM8"
/// The chunk holding the samples, and the one holding DST-compressed samples.
private let dffAudioChunkID = "DSD "
private let dffCompressedChunkID = "DST "
private let dffChunkHeaderBytes = 12

/// DSDIFF: "FRM8", a 64-bit size, "DSD ", then chunks with big-endian 64-bit sizes, each padded to
/// an even length. Reads the rate, channels and compression in `PROP`, the length of `DSD `
/// (skipped), and the tag in an `ID3 ` chunk, which taggers add though the format has none. The
/// `DIIN` title and artist aren't read.
func parseDFF(_ reader: ByteReader) throws(ParseFailure) -> TrackMetadata {
    let (stream, id3) = try dffLayout(reader)
    return TrackMetadata(tags: id3?.tags ?? TrackTags(), audio: stream.audio, art: id3?.art)
}

func dffLayout(_ reader: ByteReader) throws(ParseFailure) -> (stream: DSDStream, id3: ID3v2Tag?) {
    let header = try reader.bytes(0..<16)
    let size = try header.uint64BE(4)
    if size > UInt64(reader.size - dffChunkHeaderBytes) {
        warnTruncated(
            reader, at: 4,
            "\(dffFormID) size \(size) doesn't fit the file (\(reader.size) bytes); read what is"
                + " there")
    }
    let end = Int(min(size, UInt64(reader.size - dffChunkHeaderBytes))) + dffChunkHeaderBytes
    var rate: Int?
    var channels: Int?
    var audio: Range<Int>?
    var id3: ID3v2Tag?
    try forEachDFFChunk(reader, in: 16..<end) { chunk throws(ParseFailure) in
        switch chunk.id {
        case "PROP":
            let type = try reader.bytes(
                chunk.body.lowerBound..<min(chunk.body.upperBound, chunk.body.lowerBound + 4))
            guard type.matches("SND ", at: 0) else { return }
            try forEachDFFChunk(reader, in: chunk.body.lowerBound + 4..<chunk.body.upperBound) {
                property throws(ParseFailure) in
                let body = try reader.bytes(property.body)
                switch property.id {
                case "FS  ": rate = Int(try body.uint32BE(0))
                case "CHNL": channels = Int(try body.uint16BE(0))
                case "CMPR":
                    let compression = try body.fourCC(0)
                    guard compression == dffAudioChunkID else {
                        throw .unsupported(
                            at: property.body.lowerBound,
                            compression == dffCompressedChunkID
                                ? "DST-compressed DSDIFF" : "DSDIFF compression '\(compression)'")
                    }
                default: break
                }
            }
        case dffAudioChunkID: audio = chunk.body
        case dffCompressedChunkID:
            throw .unsupported(at: chunk.start, "DST-compressed DSDIFF")
        default:
            if id3 == nil {
                id3 = try id3Chunk(
                    reader,
                    RIFFChunk(
                        id: chunk.id, start: chunk.start, body: chunk.body,
                        declaredSize: chunk.body.count))
            }
        }
    }
    guard let rate, let channels else {
        throw .malformed(at: 16, "DSDIFF without the rate and channels in PROP")
    }
    try checkDSDFormat(channels: channels, rateHz: rate, at: 16, "DSDIFF")
    guard let audio else { throw .malformed(at: 16, "DSDIFF without a DSD chunk") }
    let stream = DSDStream(
        rateHz: rate, channels: channels, dataStart: audio.lowerBound,
        samplesPerChannel: audio.count / channels * 8, interleave: .bytes, lsbFirst: false)
    return (stream, id3)
}

/// Calls `body` with each chunk that tiles `range`. The audio chunk may run past the end, as a
/// truncated download's does: it's clamped, with a warning. Any other chunk that does is damage.
private func forEachDFFChunk(
    _ reader: ByteReader, in range: Range<Int>, _ body: (RIFFChunk) throws(ParseFailure) -> Void
) throws(ParseFailure) {
    var offset = range.lowerBound
    while offset < range.upperBound {
        try reader.step(at: offset)
        let left = range.upperBound - offset - dffChunkHeaderBytes
        guard left >= 0 else {
            throw .malformed(
                at: offset, "\(range.upperBound - offset) stray bytes at the end of a DSDIFF chunk")
        }
        let header = try reader.bytes(offset..<offset + dffChunkHeaderBytes)
        let id = try header.fourCC(0)
        let size = try header.uint64BE(4)
        let start = offset + dffChunkHeaderBytes
        guard size <= UInt64(left) else {
            guard id == dffAudioChunkID else {
                throw .malformed(
                    at: offset,
                    "DSDIFF chunk '\(id)' of \(size) bytes runs past its container (\(left) bytes"
                        + " left)")
            }
            warnTruncated(
                reader, at: offset,
                "DSDIFF chunk '\(id)' of \(size) bytes runs past the end of the file; read what is"
                    + " there")
            try body(
                RIFFChunk(id: id, start: offset, body: start..<range.upperBound, declaredSize: left)
            )
            return
        }
        let count = Int(size)
        try body(RIFFChunk(id: id, start: offset, body: start..<start + count, declaredSize: count))
        offset = min(range.upperBound, start + count + (count & 1))
    }
}
