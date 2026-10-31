import Foundation

@testable import Fixtures
@testable import Metadata

/// A file in memory, through the same reader the parsers use on disk. Records the reads so tests
/// can check what parsing cost.
final class MemorySource: ByteSource {
    let bytes: [UInt8]
    private(set) var reads: [Range<Int>] = []

    init(_ data: Data) { bytes = Array(data) }

    var size: Int { bytes.count }

    func read(_ range: Range<Int>) throws(ParseFailure) -> [UInt8] {
        precondition(range.lowerBound >= 0 && range.upperBound <= bytes.count, "read \(range)")
        reads.append(range)
        return Array(bytes[range])
    }
}

/// A library of its own, apart from FixturesTests' copy, because the two test targets run in one
/// process and would otherwise generate into the same directory at once.
let fixtureLibrary = Result { () throws -> (URL, FixtureManifest) in
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/metadata-tests")
    _ = try generateFixtures(count: coveringLibraryFileCount, in: root)
    return (root, try loadManifest(in: root))
}

func parse(_ data: Data) throws(ParseFailure) -> ParsedFile {
    try parse(ByteReader(MemorySource(data)))
}

/// The warnings from parsing `data`, which must succeed.
func warnings(_ data: Data) throws -> [MetadataWarning] { try parse(data).warnings }

/// What parsing `data` throws, or nil when it succeeds.
func failure(_ data: Data) -> ParseFailure? {
    do throws(ParseFailure) {
        _ = try parse(data)
        return nil
    } catch {
        return error
    }
}

/// Writes `data` to a temporary file for the duration of `body`, for the URL entry points.
func withFile<T>(_ data: Data, _ body: (URL) throws -> T) throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("metadata-\(UUID().uuidString)")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}

func bigEndian32(_ value: Int) -> Data {
    var data = Data()
    data.appendBigEndian(UInt32(truncatingIfNeeded: value))
    return data
}

func littleEndian32(_ value: Int) -> Data {
    var data = Data()
    data.appendLittleEndian(UInt32(truncatingIfNeeded: value))
    return data
}

func ascii(_ text: String) -> Data { Data(text.utf8) }

// MARK: FLAC

func streamInfo(rate: Int = 44_100, channels: Int = 2, bits: Int = 16, total: Int = 4410) -> Data {
    var data = Data()
    data.appendBigEndian(UInt16(4096))
    data.appendBigEndian(UInt16(4096))
    data.appendUInt24(0)
    data.appendUInt24(0)
    data.appendBigEndian(
        UInt64(rate) << 44 | UInt64(channels - 1) << 41 | UInt64(bits - 1) << 36 | UInt64(total))
    data.append(Data(count: 16))
    return data
}

/// "fLaC", the blocks with the last one flagged, then a few bytes standing in for audio frames.
func flac(_ blocks: [(type: UInt8, body: Data)]) -> Data {
    var file = ascii("fLaC")
    for (index, block) in blocks.enumerated() {
        file.append(block.type | (index == blocks.count - 1 ? 0x80 : 0))
        file.appendUInt24(block.body.count)
        file.append(block.body)
    }
    file.append(contentsOf: [0xFF, 0xF8, 0x69, 0x08, 0x00, 0x00])
    return file
}

func vorbisComment(_ fields: [String]) -> Data {
    var body = littleEndian32(6) + ascii("vendor") + littleEndian32(fields.count)
    for field in fields { body += littleEndian32(field.utf8.count) + Data(field.utf8) }
    return body
}

func flacPicture(type: Int = 3, mime: String = "image/png", image: Data) -> Data {
    bigEndian32(type) + bigEndian32(mime.utf8.count) + ascii(mime) + bigEndian32(0)
        + Data(count: 16) + bigEndian32(image.count) + image
}

// MARK: ID3v2

/// A frame with its size written the way `version` writes sizes.
func id3Frame(_ id: String, _ body: Data, version: UInt8 = 3, flags: UInt16 = 0) -> Data {
    var frame = ascii(id)
    switch version {
    case 2: frame.appendUInt24(body.count)
    case 3: frame.appendBigEndian(UInt32(body.count))
    default: frame.appendSyncsafe(body.count)
    }
    if version != 2 { frame.appendBigEndian(flags) }
    return frame + body
}

/// A text frame body: the encoding byte, then `text` in that encoding.
func id3Text(_ text: String, encoding: UInt8 = 0) -> Data {
    var body = Data([encoding])
    switch encoding {
    case 0: body.append(contentsOf: text.unicodeScalars.map { UInt8($0.value) })
    case 1:
        body.append(contentsOf: [0xFF, 0xFE])
        for unit in text.utf16 { body.appendLittleEndian(unit) }
    case 2: for unit in text.utf16 { body.appendBigEndian(unit) }
    default: body.append(Data(text.utf8))
    }
    return body
}

/// A zero after every 0xFF, which is valid unsynchronisation and simple to undo.
func unsynchronise(_ data: Data) -> Data {
    var out = Data()
    for byte in data {
        out.append(byte)
        if byte == 0xFF { out.append(0) }
    }
    return out
}

func id3Tag(
    version: UInt8 = 3, flags: UInt8 = 0, _ frames: [Data], padding: Int = 0,
    extendedHeader: Data = Data()
) -> Data {
    var body = extendedHeader
    for frame in frames { body.append(frame) }
    body.append(Data(count: padding))
    if flags & 0x80 != 0, version < 4 { body = unsynchronise(body) }
    var tag = ascii("ID3") + Data([version, 0, flags])
    tag.appendSyncsafe(body.count)
    tag.append(body)
    if flags & 0x10 != 0 {
        tag += ascii("3DI") + Data([version, 0, flags])
        tag.appendSyncsafe(body.count)
    }
    return tag
}

// MARK: MPEG audio

/// MPEG-1 Layer III, 128 kbit/s, 44.1 kHz, stereo: 417 bytes a frame.
let mpeg1Header: [UInt8] = [0xFF, 0xFB, 0x90, 0x00]
/// MPEG-2 Layer III, 64 kbit/s, 22.05 kHz, mono: 208 bytes a frame.
let mpeg2Header: [UInt8] = [0xFF, 0xF3, 0x80, 0xC0]

func mpegFrames(_ count: Int, header: [UInt8] = mpeg1Header, length: Int = 417) -> Data {
    var frames = Data()
    for _ in 0..<count { frames += Data(header) + Data(count: length - header.count) }
    return frames
}

// MARK: MP4

func fullBox(_ type: String, _ body: Data) -> Data { atom(type, Data(count: 4) + body) }

func handler(_ type: String) -> Data {
    fullBox("hdlr", Data(count: 4) + ascii(type) + Data(count: 12) + Data([0]))
}

func mediaHeader(timescale: Int, duration: Int) -> Data {
    fullBox(
        "mdhd", Data(count: 8) + bigEndian32(timescale) + bigEndian32(duration) + Data(count: 4))
}

/// The sample entry fields before the children: reserved, data reference index, version,
/// revision, vendor, channels, sample size, compression ID, packet size, 16.16 rate.
func sampleEntryFields(channels: Int, bits: Int, rate: Int) -> Data {
    var data = Data(count: 6)
    data.appendBigEndian(UInt16(1))
    data.append(Data(count: 8))
    data.appendBigEndian(UInt16(channels))
    data.appendBigEndian(UInt16(bits))
    data.append(Data(count: 4))
    data.appendBigEndian(UInt32(truncatingIfNeeded: (rate & 0xFFFF) << 16))
    return data
}

func alacEntry(rate: Int, channels: Int, bits: Int) -> Data {
    var cookie = Data(count: 4) + bigEndian32(4096) + Data([0, UInt8(bits), 40, 10, 14])
    cookie.append(UInt8(channels))
    cookie.appendBigEndian(UInt16(255))
    cookie += bigEndian32(0) + bigEndian32(0) + bigEndian32(rate)
    return atom(
        "alac", sampleEntryFields(channels: channels, bits: bits, rate: rate) + atom("alac", cookie)
    )
}

func descriptor(_ tag: UInt8, _ body: Data) -> Data {
    // The four-byte length form, as Apple's encoders write it.
    var data = Data([tag])
    let length = body.count
    data.append(contentsOf: [
        0x80 | UInt8(length >> 21 & 0x7F), 0x80 | UInt8(length >> 14 & 0x7F),
        0x80 | UInt8(length >> 7 & 0x7F), UInt8(length & 0x7F),
    ])
    return data + body
}

func mp4aEntry(audioSpecificConfig: [UInt8], channels: Int = 2, rate: Int = 44_100) -> Data {
    let decoderConfig = Data([0x40, 0x15]) + Data(count: 3) + Data(count: 8)
    let es =
        Data([0, 1, 0]) + descriptor(4, decoderConfig + descriptor(5, Data(audioSpecificConfig)))
    return atom(
        "mp4a",
        sampleEntryFields(channels: channels, bits: 16, rate: rate)
            + fullBox("esds", descriptor(3, es)))
}

/// An `ilst` item holding one `data` atom.
func ilstItem(_ type: String, code: Int, _ value: Data) -> Data {
    atom(type, atom("data", bigEndian32(code) + bigEndian32(0) + value))
}

func moov(entry: Data, timescale: Int, duration: Int, items: Data?, fullBoxMeta: Bool = true)
    -> Data
{
    let stbl = atom("stbl", fullBox("stsd", bigEndian32(1) + entry))
    let mdia = atom(
        "mdia",
        mediaHeader(timescale: timescale, duration: duration) + handler("soun")
            + atom("minf", stbl))
    var children = atom("trak", mdia)
    if let items {
        let meta = handler("mdir") + atom("ilst", items)
        children += atom(
            "udta", fullBoxMeta ? fullBox("meta", meta) : atom("meta", meta))
    }
    return atom("moov", children)
}

func mp4File(_ moov: Data, mdatBytes: Int = 64, moovFirst: Bool = true) -> Data {
    let ftyp = atom("ftyp", ascii("M4A ") + bigEndian32(0) + ascii("M4A isom"))
    let mdat = atom("mdat", Data(count: mdatBytes))
    return moovFirst ? ftyp + moov + mdat : ftyp + mdat + moov
}

// MARK: WAV and AIFF

func wavFormat(tag: UInt16 = 1, channels: Int = 2, rate: Int = 44_100, bits: Int = 16) -> Data {
    var data = Data()
    data.appendLittleEndian(tag)
    data.appendLittleEndian(UInt16(channels))
    data.appendLittleEndian(UInt32(rate))
    data.appendLittleEndian(UInt32(rate * channels * bits / 8))
    data.appendLittleEndian(UInt16(channels * bits / 8))
    data.appendLittleEndian(UInt16(bits))
    return data
}

/// An 80-bit extended float holding a whole number.
func extendedFloat(_ value: Int) -> Data {
    let exponent = 63 - UInt64(value).leadingZeroBitCount
    var data = Data()
    data.appendBigEndian(UInt16(16383 + exponent))
    data.appendBigEndian(UInt64(value) << (63 - exponent))
    return data
}

func aiffCommon(channels: Int = 2, frames: Int = 4410, bits: Int = 16, rate: Int = 44_100)
    -> Data
{
    var data = Data()
    data.appendBigEndian(UInt16(channels))
    data.appendBigEndian(UInt32(frames))
    data.appendBigEndian(UInt16(bits))
    return data + extendedFloat(rate)
}
