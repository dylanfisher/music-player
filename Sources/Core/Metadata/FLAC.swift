/// The first four bytes of a FLAC file.
package let flacMarker = "fLaC"

/// FLAC: "fLaC", then metadata blocks, each a type byte (the top bit marks the last) and a 24-bit
/// length. Reads STREAMINFO, VORBIS_COMMENT and PICTURE, and skips the rest by length.
func parseFLAC(_ reader: ByteReader) throws(ParseFailure) -> TrackMetadata {
    var offset = 4
    var audio: TrackAudio?
    var tags: TrackTags?
    var pictures: [EmbeddedPicture] = []
    var isLast = false
    while !isLast {
        try reader.step(at: offset)
        let header = try reader.bytes(offset..<offset + 4)
        let type = try header.uint8(0) & 0x7F
        isLast = try header.uint8(0) & 0x80 != 0
        let body = offset + 4..<offset + 4 + Int(try header.uint24BE(1))
        guard body.upperBound <= reader.size else {
            throw .malformed(
                at: offset,
                "FLAC metadata block (type \(type)) of \(body.count) bytes runs past the end of"
                    + " the file (\(reader.size) bytes)")
        }
        guard (type == 0) == (offset == 4) else {
            throw .malformed(at: offset, "FLAC STREAMINFO isn't the first metadata block")
        }
        switch type {
        case 0: audio = try streamInfo(try reader.bytes(body))
        case 4:
            guard tags == nil else {
                reader.warn(.unreadableField, at: offset, "a second FLAC VORBIS_COMMENT; ignored")
                break
            }
            tags = try parseVorbisComment(try reader.bytes(body), reader)
        case 6:
            // The block is inside the file, so a bad picture spoils only the picture.
            reader.skippingUnreadableField(at: offset) { () throws(ParseFailure) in
                if let picture = try flacPicture(reader, body) { pictures.append(picture) }
            }
        case 127: throw .malformed(at: offset, "FLAC metadata block type 127 is invalid")
        default: break
        }
        offset = body.upperBound
    }
    guard let audio else {
        throw .malformed(at: 4, "FLAC without a STREAMINFO block")
    }
    return TrackMetadata(
        tags: tags ?? TrackTags(), audio: audio, art: preferredPicture(pictures),
        pictures: pictures)
}

/// The MIME type FLAC PICTURE and ID3 APIC give a picture that's a URL, not embedded.
let linkedPictureMIMEType = "-->"

/// Sample rate (20 bits), channels − 1 (3), bits per sample − 1 (5) and total samples (36),
/// packed after the block and frame size limits.
private func streamInfo(_ block: Bytes) throws(ParseFailure) -> TrackAudio {
    guard block.count >= 34 else {
        throw .malformed(at: block.fileOffset(0), "FLAC STREAMINFO is \(block.count) bytes, not 34")
    }
    let packed = try block.uint64BE(10)
    let rate = Int(packed >> 44)
    guard rate > 0 else { throw .malformed(at: block.fileOffset(10), "FLAC sample rate is 0") }
    let total = Int(packed & 0xF_FFFF_FFFF)
    guard total > 0 else {
        throw .unsupported(at: block.fileOffset(13), "FLAC stream without a total sample count")
    }
    return TrackAudio(
        codec: .flac, sampleRateHz: rate, bitsPerSample: Int(packed >> 36 & 0x1F) + 1,
        channels: Int(packed >> 41 & 0x7) + 1, lengthFrames: total)
}

/// Big-endian: picture type, MIME length and MIME, description length and description, width,
/// height, depth, colors, then the image's length and the image, which is skipped.
private func flacPicture(_ reader: ByteReader, _ body: Range<Int>) throws(ParseFailure)
    -> EmbeddedPicture?
{
    var cursor = body.lowerBound
    func field(_ length: Int) throws(ParseFailure) -> Bytes {
        guard length >= 0, length <= body.upperBound - cursor else {
            throw .malformed(
                at: cursor, "FLAC PICTURE field of \(length) bytes runs past the end of its block")
        }
        defer { cursor += length }
        return try reader.bytes(cursor..<cursor + length)
    }
    let type = try field(4).uint32BE(0)
    let mime = latin1(try field(Int(try field(4).uint32BE(0))).array)
    _ = try field(Int(try field(4).uint32BE(0)))
    _ = try field(16)
    let length = Int(try field(4).uint32BE(0))
    let imageOffset = cursor
    guard length <= body.upperBound - imageOffset else {
        throw .malformed(
            at: imageOffset, "FLAC picture of \(length) bytes runs past the end of its block")
    }
    if mime == linkedPictureMIMEType { return nil }
    return EmbeddedPicture(
        art: EmbeddedArt(
            offset: imageOffset, byteCount: length, mimeType: mime, unsynchronised: false),
        type: type)
}
