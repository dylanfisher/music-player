import Foundation

package let riffFormID = "RIFF"
/// The chunk holding the samples, which a tag must not overlap.
package let wavAudioChunkID = "data"
let wavFormType = "WAVE"

/// `LIST/INFO` fields and what they set. INFO has no album artist, totals or compilation flag,
/// and of the fields added since only a copyright.
private let infoFields: [String: TagField] = [
    "INAM": .title, "IART": .artist, "IPRD": .album, "IGNR": .genre, "ICRD": .date,
    "ITRK": .track, "IPRT": .track, "ICMT": .comment, "ICOP": .copyright,
]

private let formatTags: [UInt16: String] = [1: "integer PCM", 3: "floating-point PCM"]
private let extensibleFormat: UInt16 = 0xFFFE

/// WAV: "RIFF", a size, "WAVE", then chunks. Reads `fmt `, the size of `data` (skipped), and the
/// tags in `LIST/INFO` and `id3 `. Where both hold a field, ID3 wins, since it holds more.
func parseWAV(_ reader: ByteReader) throws(ParseFailure) -> TrackMetadata {
    let header = try reader.bytes(0..<12)
    let end = try formEnd(reader, size: Int(try header.uint32LE(4)), form: riffFormID)
    var format: Bytes?
    var dataBytes: Int?
    var info = TrackTags()
    var id3: ID3v2Tag?
    try forEachChunk(
        reader, in: 12..<end, littleEndian: true, form: riffFormID,
        audioID: wavAudioChunkID
    ) {
        chunk throws(ParseFailure) in
        switch chunk.id {
        case "fmt ": format = try reader.bytes(chunk.body)
        case wavAudioChunkID: dataBytes = chunk.body.count
        case "LIST":
            let type = try reader.bytes(
                chunk.body.lowerBound..<min(chunk.body.upperBound, chunk.body.lowerBound + 4))
            guard type.matches("INFO", at: 0) else { return }
            info = try infoTags(reader, chunk)
        default: if id3 == nil { id3 = try id3Chunk(reader, chunk) }
        }
    }
    guard let format else { throw .malformed(at: 12, "WAV without a fmt chunk") }
    guard let dataBytes else { throw .malformed(at: 12, "WAV without a data chunk") }
    return TrackMetadata(
        tags: (id3?.tags ?? TrackTags()).filling(from: info),
        audio: try wavAudio(format, dataBytes: dataBytes), art: id3?.art)
}

/// Format tag, channels, rate, byte rate, block align, bits per sample; then for
/// WAVE_FORMAT_EXTENSIBLE an extension size, valid bits, channel mask and a sub-format GUID whose
/// first two bytes are the real format tag.
private func wavAudio(_ format: Bytes, dataBytes: Int) throws(ParseFailure) -> TrackAudio {
    var tag = try format.uint16LE(0)
    let channels = Int(try format.uint16LE(2))
    let rate = Int(try format.uint32LE(4))
    let blockAlign = Int(try format.uint16LE(12))
    var bits = Int(try format.uint16LE(14))
    if tag == extensibleFormat {
        let valid = Int(try format.uint16LE(18))
        if valid > 0 { bits = valid }
        tag = try format.uint16LE(24)
    }
    guard formatTags[tag] != nil else {
        throw .unsupported(at: format.fileOffset(0), "WAV format tag 0x\(String(tag, radix: 16))")
    }
    guard channels > 0, rate > 0, bits > 0, blockAlign > 0 else {
        throw .malformed(
            at: format.fileOffset(0),
            "WAV fmt has \(channels) channels, \(rate) Hz, \(bits) bits, block align \(blockAlign)")
    }
    return TrackAudio(
        codec: .pcm, sampleRateHz: rate, bitsPerSample: bits, channels: channels,
        lengthFrames: dataBytes / blockAlign)
}

/// "INFO", then text chunks. Values end with a NUL. INFO declares no encoding: most taggers
/// write UTF-8, older ones Latin-1, so text that isn't UTF-8 is read as Latin-1.
private func infoTags(_ reader: ByteReader, _ list: RIFFChunk) throws(ParseFailure) -> TrackTags {
    var tags = TrackTags()
    try forEachChunk(
        reader, in: list.body.lowerBound + 4..<list.body.upperBound, littleEndian: true,
        form: list.id
    ) { field throws(ParseFailure) in
        guard let tagField = infoFields[field.id] else { return }
        var bytes = try reader.bytes(field.body).array
        while bytes.last == 0 { bytes.removeLast() }
        tags.set(
            tagField, String(bytes: bytes, encoding: .utf8) ?? latin1(bytes),
            at: field.body.lowerBound, warnings: &reader.warnings)
    }
    return tags
}
