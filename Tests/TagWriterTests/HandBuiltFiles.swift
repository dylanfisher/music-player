import Foundation
import Testing

@testable import Metadata
@testable import TagWriter

/// A text frame of `version`: Latin-1, no flags.
func id3TextFrame(_ id: String, _ text: String, version: UInt8 = 3) -> [UInt8] {
    try! ID3Frame(id: id, body: [0] + Array(text.utf8), version: version).raw
}

/// An ID3v2 tag of `frames` and `padding`, with `flags` in its header.
func id3Tag(_ frames: [[UInt8]], version: UInt8 = 3, flags: UInt8 = 0, padding: Int = 64)
    -> [UInt8]
{
    let body = frames.flatMap { $0 } + [UInt8](repeating: 0, count: padding)
    return Array("ID3".utf8) + [version, 0, flags] + (try! syncsafeBytes(body.count)) + body
}

/// The MP3 sample's audio frames behind a tag of our own.
func mp3(withTag tag: [UInt8]) throws -> URL {
    let url = try Sample.mp3Untagged.copy()
    let audio = try Data(contentsOf: url)
    try (Data(tag) + audio).write(to: url)
    return url
}

/// The FLAC sample's STREAMINFO and audio frames, with a Vorbis comment block of `comments`
/// and, when `padding` isn't nil, a PADDING block of that many bytes.
func flac(comments: [String], padding: Int?) throws -> URL {
    let url = try Sample.flac.copy()
    let file = try FLACFile(ByteReader(FileSource(path: url.path)))
    let streamInfo = try #require(file.blocks.first { $0.type == 0 }).body
    let audio = try Data(contentsOf: url)[file.audioStart...]
    let vendor = Array("hand built".utf8)
    var vorbis = littleEndianBytes(vendor.count, 4) + vendor + littleEndianBytes(comments.count, 4)
    for comment in comments {
        vorbis += littleEndianBytes(comment.utf8.count, 4) + Array(comment.utf8)
    }
    var blocks: [(UInt8, [UInt8])] = [(0, streamInfo), (4, vorbis)]
    if let padding { blocks.append((1, [UInt8](repeating: 0, count: padding))) }
    var bytes = FLACFile.marker
    for (index, block) in blocks.enumerated() {
        bytes.append(block.0 | (index == blocks.count - 1 ? 0x80 : 0))
        bytes += bigEndianBytes(block.1.count, 3) + block.1
    }
    try (Data(bytes) + audio).write(to: url)
    return url
}

/// The MP4 sample with every `stco` turned into a `co64`, its entries moved by the growth.
func mp4WithCo64() throws -> URL {
    let url = try Sample.mp4.copy()
    let file = try MP4File(ByteReader(FileSource(path: url.path)))
    var moov = file.moov
    let tables = moov.chunkOffsetTables()
    let growth = try tables.reduce(0) { $0 + 4 * (try moov[$1].chunkOffsets().count) }
    for path in tables {
        let offsets = try moov[path].chunkOffsets()
        var body = Array(moov[path].body.prefix(8))
        for offset in offsets { body += bigEndianBytes(offset + growth, 8) }
        moov[path] = MP4Box(type: MP4Type.co64, body: body)
    }
    let bytes = try Data(contentsOf: url)
    var moved = bytes[..<file.moovAtom.start]
    moved += moov.serialized()
    moved += bytes[file.moovAtom.body.upperBound...]
    try moved.write(to: url)
    return url
}

/// `sample` with its ID3 chunk moved in front of the audio chunk.
func formWithID3BeforeAudio(_ sample: Sample) throws -> URL {
    let url = try sample.copy()
    let file = try ID3File(
        ByteReader(FileSource(path: url.path)), container: sample == .wavID3 ? .wav : .aiff)
    guard case .form(_, let tagChunk?, let chunks, _) = file.host else {
        throw SampleMissing(sample: sample)
    }
    let bytes = try Data(contentsOf: url)
    func whole(_ chunk: RIFFChunk) -> Data {
        bytes[chunk.start..<chunk.body.upperBound + chunk.body.count % 2]
    }
    var body = Data()
    for chunk in chunks where chunk.start != tagChunk.start {
        if chunk.body == file.payload { body += whole(tagChunk) }
        body += whole(chunk)
    }
    try (bytes[..<12] + body).write(to: url)
    return url
}
