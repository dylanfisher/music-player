/// What MPEG-4 audio's AudioSpecificConfig says about the stream.
struct AudioSpecificConfig {
    var sampleRateHz: Int
    /// Nil when the channel layout is in a program config element; the sample entry's count holds.
    var channels: Int?
}

private let samplingFrequencies = [
    96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025,
    8_000, 7_350,
]

/// AAC's object types: Main, LC, SSR, LTP, SBR and PS. SBR and PS report the core rate.
private let aacObjectTypes: Set<UInt64> = [1, 2, 3, 4, 5, 29]

/// The body of `esds` after its version and flags: an ES descriptor (tag 3) holding a decoder
/// config descriptor (tag 4) holding the decoder-specific info (tag 5), which is the
/// AudioSpecificConfig.
func audioSpecificConfig(_ esds: Bytes) throws(ParseFailure) -> AudioSpecificConfig {
    var es = try descriptor(esds, at: 0, tag: 3)
    let flags = try es.uint8(2)
    var cursor = 3
    if flags & 0x80 != 0 { cursor += 2 }  // depends on another stream
    if flags & 0x40 != 0 { cursor += 1 + Int(try es.uint8(cursor)) }  // URL
    if flags & 0x20 != 0 { cursor += 2 }  // OCR stream
    es = try es.suffix(from: cursor)
    let decoderConfig = try descriptor(es, at: 0, tag: 4)
    let objectType = try decoderConfig.uint8(0)
    guard objectType == 0x40 else {
        throw .unsupported(
            at: decoderConfig.fileOffset(0),
            "MP4 audio object type indication 0x\(String(objectType, radix: 16)), not MPEG-4 audio")
    }
    var bits = BitReader(try descriptor(decoderConfig, at: 13, tag: 5))
    var audioObjectType = try bits.read(5)
    if audioObjectType == 31 { audioObjectType = 32 + (try bits.read(6)) }
    guard aacObjectTypes.contains(audioObjectType) else {
        throw .unsupported(
            at: decoderConfig.fileOffset(13), "MPEG-4 audio object type \(audioObjectType)")
    }
    let frequencyIndex = Int(try bits.read(4))
    let rate: Int
    if frequencyIndex == 15 {
        rate = Int(try bits.read(24))
    } else if frequencyIndex < samplingFrequencies.count {
        rate = samplingFrequencies[frequencyIndex]
    } else {
        throw .malformed(
            at: decoderConfig.fileOffset(13), "AAC sampling frequency index \(frequencyIndex)")
    }
    guard rate > 0 else {
        throw .malformed(at: decoderConfig.fileOffset(13), "AAC sample rate is 0")
    }
    let channelConfiguration = Int(try bits.read(4))
    let channels: Int? =
        switch channelConfiguration {
        case 1...6: channelConfiguration
        case 7: 8
        // 0 puts the layout in-band, and 8 and up are reserved or have no plain count; the sample
        // entry's count stands.
        default: nil
        }
    return AudioSpecificConfig(sampleRateHz: rate, channels: channels)
}

/// The body of the descriptor at `offset`, which must have tag `tag`. Its length is up to four
/// bytes of seven bits, the top bit marking that another follows.
private func descriptor(_ bytes: Bytes, at offset: Int, tag: UInt8) throws(ParseFailure) -> Bytes {
    let found = try bytes.uint8(offset)
    guard found == tag else {
        throw .malformed(
            at: bytes.fileOffset(offset), "MP4 esds descriptor has tag \(found), not \(tag)")
    }
    var length = 0
    var cursor = offset + 1
    for index in 0..<4 {
        let byte = try bytes.uint8(cursor)
        cursor += 1
        length = length << 7 | Int(byte & 0x7F)
        if byte & 0x80 == 0 { break }
        if index == 3 {
            throw .malformed(at: bytes.fileOffset(offset), "MP4 esds descriptor length is too long")
        }
    }
    return try bytes.slice(cursor..<cursor + length)
}

/// Reads big-endian bit fields.
private struct BitReader {
    let bytes: Bytes
    var position = 0

    init(_ bytes: Bytes) { self.bytes = bytes }

    mutating func read(_ count: Int) throws(ParseFailure) -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<count {
            let byte = try bytes.uint8(position / 8)
            value = value << 1 | UInt64(byte >> (7 - UInt8(position % 8)) & 1)
            position += 1
        }
        return value
    }
}
