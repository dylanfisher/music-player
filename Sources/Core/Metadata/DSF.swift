/// The DSF header's ID, which is also the form type of a DSDIFF file.
let dsfHeaderID = "DSD "
private let dsfHeaderBytes = 28
private let dsfFormatBytes = 52
private let dsfDataHeaderBytes = 12
private let dsfDataOffset = 80
/// DSF's own block size is 4096; anything far past it is damage.
private let maximumDSFBlockBytes = 65_536

/// DSF: a "DSD " header, a "fmt " chunk and a "data" chunk, each with a 64-bit little-endian size
/// that counts its own header, then the ID3v2 tag the header's metadata pointer locates. The tag
/// is apart from the audio, so one that can't be read is a warning and the file reads untagged.
func parseDSF(_ reader: ByteReader) throws(ParseFailure) -> TrackMetadata {
    let (stream, tagOffset) = try dsfLayout(reader)
    var id3: ID3v2Tag?
    if let tagOffset {
        do throws(ParseFailure) {
            id3 = try parseID3v2(reader, at: tagOffset, end: reader.size, container: wholeFileName)
        } catch {
            reader.warn(
                .unreadableField, at: error.offset ?? tagOffset,
                "DSF tag at the metadata pointer can't be read (\(error.detail)); read without tags"
            )
        }
    }
    return TrackMetadata(tags: id3?.tags ?? TrackTags(), audio: stream.audio, art: id3?.art)
}

/// The audio's layout, and where the ID3v2 tag starts if the file has one.
func dsfLayout(_ reader: ByteReader) throws(ParseFailure) -> (stream: DSDStream, tagOffset: Int?) {
    let header = try reader.bytes(0..<dsfHeaderBytes)
    guard try header.uint64LE(4) == UInt64(dsfHeaderBytes) else {
        throw .malformed(at: 4, "DSF header size isn't \(dsfHeaderBytes)")
    }
    let fileBytes = try header.uint64LE(12)
    let pointer = try header.uint64LE(20)
    if fileBytes > UInt64(reader.size) {
        warnTruncated(
            reader, at: 12,
            "DSF header gives \(fileBytes) bytes, more than the file's \(reader.size); read what"
                + " is there")
    }

    let format = try reader.bytes(dsfHeaderBytes..<dsfHeaderBytes + dsfFormatBytes)
    guard format.matches("fmt ", at: 0), try format.uint64LE(4) == UInt64(dsfFormatBytes) else {
        throw .malformed(at: dsfHeaderBytes, "DSF without a \(dsfFormatBytes)-byte fmt chunk")
    }
    let version = try format.uint32LE(12)
    guard version == 1 else {
        throw .unsupported(at: format.fileOffset(12), "DSF format version \(version)")
    }
    let formatID = try format.uint32LE(16)
    guard formatID == 0 else {
        throw .unsupported(at: format.fileOffset(16), "DSF format \(formatID), not plain DSD")
    }
    let channels = Int(try format.uint32LE(24))
    let rate = Int(try format.uint32LE(28))
    try checkDSDFormat(channels: channels, rateHz: rate, at: format.fileOffset(24), "DSF")
    let bits = try format.uint32LE(32)
    guard bits == 1 || bits == 8 else {
        throw .malformed(at: format.fileOffset(32), "DSF with \(bits) bits per sample, not 1 or 8")
    }
    let sampleCount = try format.uint64LE(36)
    let blockBytes = Int(try format.uint32LE(44))
    guard blockBytes > 0, blockBytes <= maximumDSFBlockBytes else {
        throw .malformed(at: format.fileOffset(44), "DSF block size \(blockBytes)")
    }

    let data = try reader.bytes(dsfDataOffset..<dsfDataOffset + dsfDataHeaderBytes)
    let dataSize = try data.uint64LE(4)
    guard data.matches("data", at: 0), dataSize >= UInt64(dsfDataHeaderBytes) else {
        throw .malformed(at: dsfDataOffset, "DSF without a data chunk after fmt")
    }
    let dataStart = dsfDataOffset + dsfDataHeaderBytes
    let available = reader.size - dataStart
    let declared = dataSize - UInt64(dsfDataHeaderBytes)
    if declared > UInt64(available) {
        warnTruncated(
            reader, at: dsfDataOffset,
            "DSF data of \(declared) bytes runs past the end of the file; read what is there")
    }
    let present = Int(min(declared, UInt64(available)))
    // The last group of blocks may be cut short, leaving the later channels fewer bytes.
    let group = blockBytes * channels
    let rest = present % group
    let presentPerChannel =
        present / group * blockBytes + max(0, min(blockBytes, rest - (channels - 1) * blockBytes))
    // Bits 1 means the oldest bit is the lowest of each byte; 8 means the highest.
    let stream = DSDStream(
        rateHz: rate, channels: channels, dataStart: dataStart,
        samplesPerChannel: Int(min(sampleCount, UInt64(presentPerChannel) * 8)),
        interleave: .blocks(blockBytes: blockBytes), lsbFirst: bits == 1)

    guard pointer != 0 else { return (stream, nil) }
    guard pointer >= UInt64(dataStart + present) else {
        reader.warn(
            .unreadableField, at: 20,
            "DSF metadata pointer \(pointer) is inside the header or the audio; read without tags")
        return (stream, nil)
    }
    guard pointer < UInt64(reader.size) else {
        warnTruncated(
            reader, at: 20,
            "DSF metadata pointer \(pointer) is past the end of the file (\(reader.size) bytes);"
                + " read without tags")
        return (stream, nil)
    }
    return (stream, Int(pointer))
}
