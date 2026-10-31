/// AIFC compression types that are plain PCM: big-endian, little-endian ("sowt"), and float.
private let pcmCompressionTypes: Set<String> = [
    "NONE", "twos", "sowt", "fl32", "FL32", "fl64", "FL64",
]

/// AIFF and AIFC: "FORM", a size, the form type, then big-endian chunks. Reads `COMM` and the
/// tag in `ID3 `; `SSND` is skipped. The `NAME`, `AUTH` and `ANNO` text chunks aren't read.
func parseAIFF(_ reader: ByteReader) throws(ParseFailure) -> TrackMetadata {
    let header = try reader.bytes(0..<12)
    let isAIFC = header.matches("AIFC", at: 8)
    let formEnd = 8 + Int(try header.uint32BE(4))
    guard formEnd >= 12, formEnd <= reader.size + 1 else {
        throw .malformed(
            at: 4, "FORM size \(formEnd - 8) doesn't fit the file (\(reader.size) bytes)")
    }
    var audio: TrackAudio?
    var id3: ID3v2Tag?
    try forEachChunk(reader, in: 12..<min(formEnd, reader.size), littleEndian: false, form: "FORM")
    {
        chunk throws(ParseFailure) in
        if chunk.id == "COMM" {
            audio = try commonChunk(try reader.bytes(chunk.body), isAIFC: isAIFC)
        } else if isID3Chunk(chunk.id), id3 == nil {
            id3 = try parseID3v2(
                reader, at: chunk.body.lowerBound, end: chunk.body.upperBound,
                container: "its chunk")
        }
    }
    guard let audio else { throw .malformed(at: 12, "AIFF without a COMM chunk") }
    return TrackMetadata(tags: id3?.tags ?? TrackTags(), audio: audio, art: id3?.art)
}

/// Channels, frames, bits per sample, then the rate as an 80-bit extended float. AIFC adds the
/// compression type.
private func commonChunk(_ comm: Bytes, isAIFC: Bool) throws(ParseFailure) -> TrackAudio {
    let channels = Int(try comm.uint16BE(0))
    let frames = Int(try comm.uint32BE(2))
    let bits = Int(try comm.uint16BE(6))
    let rate = try extendedFloat(comm, at: 8)
    if isAIFC {
        let compression = try comm.fourCC(18)
        guard pcmCompressionTypes.contains(compression) else {
            throw .unsupported(at: comm.fileOffset(18), "AIFC compression '\(compression)'")
        }
    }
    guard channels > 0, bits > 0, let rate, rate > 0 else {
        throw .malformed(
            at: comm.fileOffset(0),
            "AIFF COMM has \(channels) channels, \(bits) bits, rate \(rate.map(String.init) ?? "invalid")"
        )
    }
    return TrackAudio(
        codec: .pcm, sampleRateHz: rate, bitsPerSample: bits, channels: channels,
        lengthFrames: frames)
}

/// A sign bit and 15-bit exponent, then a 64-bit mantissa with an explicit integer bit. Nil
/// unless it's a whole number of hertz that fits an Int32.
private func extendedFloat(_ bytes: Bytes, at offset: Int) throws(ParseFailure) -> Int? {
    let exponent = Int(try bytes.uint16BE(offset))
    let mantissa = try bytes.uint64BE(offset + 2)
    guard exponent & 0x8000 == 0 else { return nil }
    let shift = 16383 + 63 - exponent
    guard shift >= 0, shift < 64 else { return nil }
    guard mantissa & ((1 << UInt64(shift)) - 1) == 0 else { return nil }
    let value = mantissa >> UInt64(shift)
    return value <= UInt64(Int32.max) ? Int(value) : nil
}
