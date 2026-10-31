import Foundation
import Log

/// How a FLAC file's Vorbis comments are written, varied so parsers meet what real taggers do.
struct VorbisStyle: Sendable {
    /// Keys are case-insensitive; most taggers write them uppercase.
    var lowercaseKeys: Bool
    /// "3/12" in TRACKNUMBER instead of a separate TRACKTOTAL.
    var combinedTrackNumber: Bool
    var paddingBytes: Int
}

/// STREAMINFO, then a VORBIS_COMMENT and a PICTURE when there are tags and art, then PADDING,
/// then the seed's audio frames.
func flacFile(
    streamInfo: Data, frames: Data, tags: FixtureTags?, art: Artwork?, style: VorbisStyle
) -> Data {
    var blocks: [(type: UInt8, body: Data)] = [(0, streamInfo)]
    if let tags { blocks.append((4, vorbisComment(tags, style))) }
    if let art { blocks.append((6, picture(art))) }
    if style.paddingBytes > 0 { blocks.append((1, Data(count: style.paddingBytes))) }

    var file = Data()
    file.append(ascii: "fLaC")
    for (index, block) in blocks.enumerated() {
        file.append(block.type | (index == blocks.count - 1 ? 0x80 : 0))
        file.appendUInt24(block.body.count)
        file.append(block.body)
    }
    file.append(frames)
    return file
}

/// Where the VORBIS_COMMENT block's header starts: after "fLaC" and STREAMINFO.
let flacCommentHeaderOffset = 4 + 4 + 34
let flacVendor = "\(appDirectoryName) fixtures"

/// Little-endian lengths, unlike the rest of FLAC: the vendor, the count, then `KEY=value`s.
private func vorbisComment(_ tags: FixtureTags, _ style: VorbisStyle) -> Data {
    var fields: [(String, String?)] = [
        ("TITLE", tags.title), ("ARTIST", tags.artist), ("ALBUM", tags.album),
        ("ALBUMARTIST", tags.albumArtist), ("GENRE", tags.genre), ("DATE", tags.date),
    ]
    if style.combinedTrackNumber, let track = tags.trackNumber {
        fields.append(("TRACKNUMBER", tags.trackTotal.map { "\(track)/\($0)" } ?? "\(track)"))
    } else {
        fields.append(("TRACKNUMBER", tags.trackNumber.map(String.init)))
        fields.append(("TRACKTOTAL", tags.trackTotal.map(String.init)))
    }
    fields.append(("DISCNUMBER", tags.discNumber.map(String.init)))
    fields.append(("DISCTOTAL", tags.discTotal.map(String.init)))
    fields.append(("COMPILATION", tags.compilation ? "1" : nil))
    fields.append(("COMMENT", tags.comment))

    let present = fields.compactMap { key, value in
        value.map { (style.lowercaseKeys ? key.lowercased() : key) + "=" + $0 }
    }
    var body = Data()
    body.appendLittleEndian(UInt32(flacVendor.utf8.count))
    body.append(ascii: flacVendor)
    body.appendLittleEndian(UInt32(present.count))
    for field in present {
        body.appendLittleEndian(UInt32(field.utf8.count))
        body.append(contentsOf: Array(field.utf8))
    }
    return body
}

/// Big-endian: picture type 3 (front cover), MIME type, empty description, size, depth, then
/// the image.
private func picture(_ art: Artwork) -> Data {
    var body = Data()
    body.appendBigEndian(UInt32(3))
    body.appendBigEndian(UInt32(art.mimeType.utf8.count))
    body.append(ascii: art.mimeType)
    body.appendBigEndian(UInt32(0))
    body.appendBigEndian(UInt32(art.width))
    body.appendBigEndian(UInt32(art.height))
    body.appendBigEndian(UInt32(24))
    body.appendBigEndian(UInt32(0))
    body.appendBigEndian(UInt32(art.data.count))
    body.append(art.data)
    return body
}
