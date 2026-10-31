import Foundation

enum ID3Version: UInt8, Sendable {
    case v22 = 2
    case v23 = 3
    case v24 = 4

    var tagFormat: FixtureFile.TagFormat {
        switch self {
        case .v22: .id3v22
        case .v23: .id3v23
        case .v24: .id3v24
        }
    }
}

/// How an ID3v2 tag is written, varied so parsers meet what real taggers do.
struct ID3Style: Sendable {
    var version: ID3Version
    /// UTF-16 even where Latin-1 (2.2, 2.3) or UTF-8 (2.4) would do.
    var preferUTF16: Bool
    /// The genre as an ID3v1 reference, "(17)", where it has one.
    var genreAsReference: Bool
    var paddingBytes: Int
}

/// A complete tag: header, frames, padding. No unsynchronisation, compression or extended header.
func id3Tag(_ tags: FixtureTags, art: Artwork?, style: ID3Style) -> Data {
    let version = style.version
    var frames = Data()
    func text(_ ids: (String, String), _ value: String?) {
        guard let value else { return }
        var body = Data([encoding(for: value, style)])
        body.append(encode(value, encoding(for: value, style)))
        frames.append(frame(version == .v22 ? ids.0 : ids.1, body, version))
    }

    text(("TT2", "TIT2"), tags.title)
    text(("TP1", "TPE1"), tags.artist)
    text(("TAL", "TALB"), tags.album)
    text(("TP2", "TPE2"), tags.albumArtist)
    if let genre = tags.genre {
        let reference = style.genreAsReference ? id3v1GenreIndex(genre).map { "(\($0))" } : nil
        text(("TCO", "TCON"), reference ?? genre)
    }
    if version == .v24 {
        text(("", "TDRC"), tags.date)
    } else {
        text(("TYE", "TYER"), tags.date.map { String($0.prefix(4)) })
    }
    text(
        ("TRK", "TRCK"),
        tags.trackNumber.map { n in tags.trackTotal.map { "\(n)/\($0)" } ?? "\(n)" })
    text(
        ("TPA", "TPOS"), tags.discNumber.map { n in tags.discTotal.map { "\(n)/\($0)" } ?? "\(n)" })
    text(("TCP", "TCMP"), tags.compilation ? "1" : nil)
    if let comment = tags.comment {
        let encoding = encoding(for: comment, style)
        var body = Data([encoding])
        body.append(ascii: "eng")
        body.append(encode("", encoding) + terminator(encoding))
        body.append(encode(comment, encoding))
        frames.append(frame(version == .v22 ? "COM" : "COMM", body, version))
    }
    if let art {
        var body = Data([0])
        if version == .v22 {
            body.append(ascii: art.mimeType == "image/png" ? "PNG" : "JPG")
        } else {
            body.append(ascii: art.mimeType)
            body.append(0)
        }
        body.append(3)  // front cover
        body.append(0)  // empty description
        body.append(art.data)
        frames.append(frame(version == .v22 ? "PIC" : "APIC", body, version))
    }

    var tag = Data()
    tag.append(ascii: "ID3")
    tag.append(contentsOf: [version.rawValue, 0, 0])
    tag.appendSyncsafe(frames.count + style.paddingBytes)
    tag.append(frames)
    tag.append(Data(count: style.paddingBytes))
    return tag
}

/// Only ID3v2.2 and 2.3 store just the year.
func id3Subset(_ tags: FixtureTags, _ version: ID3Version) -> FixtureTags {
    var tags = tags
    if version != .v24 { tags.date = tags.date.map { String($0.prefix(4)) } }
    return tags
}

/// The first frame's size field, for breaking it on purpose.
let id3FirstFrameSizeOffset = 10 + 4

private func frame(_ id: String, _ body: Data, _ version: ID3Version) -> Data {
    var frame = Data()
    frame.append(ascii: id)
    switch version {
    case .v22: frame.appendUInt24(body.count)
    case .v23: frame.appendBigEndian(UInt32(body.count))
    case .v24: frame.appendSyncsafe(body.count)
    }
    if version != .v22 { frame.append(contentsOf: [0, 0]) }
    frame.append(body)
    return frame
}

/// 0 Latin-1, 1 UTF-16 with a byte-order mark, 3 UTF-8 (2.4 only).
private func encoding(for text: String, _ style: ID3Style) -> UInt8 {
    if style.preferUTF16 { return 1 }
    if style.version == .v24 { return 3 }
    return text.unicodeScalars.allSatisfy { $0.value <= 0xFF } ? 0 : 1
}

private func encode(_ text: String, _ encoding: UInt8) -> Data {
    switch encoding {
    case 0: return Data(text.unicodeScalars.map { UInt8($0.value) })
    case 1:
        var data = Data([0xFF, 0xFE])
        for unit in text.utf16 { data.appendLittleEndian(unit) }
        return data
    default: return Data(text.utf8)
    }
}

private func terminator(_ encoding: UInt8) -> Data {
    encoding == 1 ? Data([0, 0]) : Data([0])
}
