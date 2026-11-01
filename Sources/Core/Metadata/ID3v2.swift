/// The first bytes of an ID3v2 tag.
package let id3v2Identifier = "ID3"

/// An ID3v2 tag's fields and art, and how many bytes the tag takes.
struct ID3v2Tag {
    var tags: TrackTags
    var art: EmbeddedArt?
    /// Header, extended header, frames, padding and footer.
    var byteCount: Int
}

private enum FrameKind {
    case text(TagField)
    /// `TCON`, which may refer to the ID3v1 list.
    case genre
    /// `COMM`; only the one with an empty description is the user's comment.
    case comment
    case picture
    /// 2.3's `TDAT` (DDMM) and `TIME` (HHMM), which refine `TYER` into a full date.
    case day, time
}

/// The 2.3 and 2.4 frames the reader and the tag writer both name.
package enum ID3FrameID {
    package static let title = "TIT2"
    package static let artist = "TPE1"
    package static let album = "TALB"
    package static let albumArtist = "TPE2"
    package static let genre = "TCON"
    package static let date = "TDRC"
    package static let track = "TRCK"
    package static let disc = "TPOS"
    package static let compilation = "TCMP"
    package static let composer = "TCOM"
    package static let comment = "COMM"
}

/// ID3v2.2 has three-character IDs, 2.3 and 2.4 four. `TDRC` is 2.4's date and `TYER` 2.3's year;
/// taggers mix them, so both are read in every version.
private let frameKinds: [String: FrameKind] = [
    "TT2": .text(.title), "TP1": .text(.artist), "TAL": .text(.album),
    "TP2": .text(.albumArtist), "TCO": .genre, "TYE": .text(.date), "TRK": .text(.track),
    "TPA": .text(.disc), "TCP": .text(.compilation), "TCM": .text(.composer), "COM": .comment,
    "PIC": .picture,
    ID3FrameID.title: .text(.title), ID3FrameID.artist: .text(.artist),
    ID3FrameID.album: .text(.album), ID3FrameID.albumArtist: .text(.albumArtist),
    ID3FrameID.genre: .genre, ID3FrameID.date: .text(.date), id3v23YearFrameID: .text(.date),
    ID3FrameID.track: .text(.track), ID3FrameID.disc: .text(.disc),
    ID3FrameID.compilation: .text(.compilation), ID3FrameID.composer: .text(.composer),
    ID3FrameID.comment: .comment, "APIC": .picture,
    id3v23DayFrameID: .day, id3v23TimeFrameID: .time,
]

/// ID3v2.3 holds a date as `TYER`, `TDAT` and `TIME`.
package let id3v23YearFrameID = "TYER"
package let id3v23DayFrameID = "TDAT"
package let id3v23TimeFrameID = "TIME"

/// The frame IDs the reader maps onto `field`, so a writer replaces exactly those.
package func id3FrameIDs(for field: TagField) -> Set<String> {
    Set(
        frameKinds.compactMap { id, kind in
            switch kind {
            case .text(let each): each == field ? id : nil
            case .genre: field == .genre ? id : nil
            case .comment: field == .comment ? id : nil
            case .day, .time: field == .date ? id : nil
            case .picture: nil
            }
        })
}

/// "ID3v2.3" for version 3.
package func id3VersionName(_ version: UInt8) -> String { "ID3v2.\(version)" }

package let id3SizeNotSyncsafe = "ID3v2 tag size isn't a syncsafe integer"

/// The frame IDs the reader takes art from.
package let id3PictureFrameIDs = Set(
    frameKinds.compactMap { id, kind in if case .picture = kind { id } else { nil } })

/// How far into a picture frame to read for its MIME type and description. Longer headers are
/// read whole.
private let pictureHeaderBytes = 1024

/// The tag body's frames: in the file, or decoded into memory when the whole tag is
/// unsynchronised, because then frame sizes count decoded bytes.
private struct FrameArea {
    var range: Range<Int>
    var reader: ByteReader
    /// Set when the tag was decoded; `range` then indexes it rather than the file.
    var decoded: Bytes?

    func bytes(_ range: Range<Int>) throws(ParseFailure) -> Bytes {
        if let decoded { return try decoded.slice(range) }
        return try reader.bytes(range)
    }

    func fileOffset(_ position: Int) -> Int { decoded?.fileOffset(position) ?? position }
}

/// Reads the ID3v2 tag at `start`, which must end by `end`: the end of the file for MP3, or of
/// the chunk for WAV and AIFF. `container` names that limit in errors.
func parseID3v2(_ reader: ByteReader, at start: Int, end: Int, container: String)
    throws(ParseFailure) -> ID3v2Tag
{
    guard end - start >= 10 else {
        throw .malformed(at: start, "ID3v2 header cut off by the end of \(container)")
    }
    let header = try reader.bytes(start..<start + 10)
    guard header.matches(id3v2Identifier, at: 0) else {
        throw .malformed(at: start, "\(container) doesn't start with an ID3v2 tag")
    }
    let version = try header.uint8(3)
    guard (2...4).contains(version) else {
        throw .unsupported(at: start, id3VersionName(version))
    }
    let flags = try header.uint8(5)
    let knownFlags: UInt8 = [2: 0xC0, 3: 0xE0, 4: 0xF0][version]!
    guard flags & ~knownFlags == 0 else {
        throw .malformed(at: start + 5, "ID3v2.\(version) tag has unknown flags \(flags)")
    }
    if version == 2, flags & 0x40 != 0 {
        throw .unsupported(at: start + 5, "compressed ID3v2.2 tag")
    }
    guard let size = try header.syncsafe(6) else {
        throw .malformed(at: start + 6, id3SizeNotSyncsafe)
    }
    let footer = version == 4 && flags & 0x10 != 0 ? 10 : 0
    let byteCount = 10 + size + footer
    guard byteCount <= end - start else {
        throw .malformed(
            at: start,
            "ID3v2 tag of \(byteCount) bytes runs past the end of \(container)"
                + " (\(end - start) bytes from the tag)")
    }

    let body = start + 10..<start + 10 + size
    let tagUnsynchronised = flags & 0x80 != 0
    var area = FrameArea(range: body, reader: reader)
    if tagUnsynchronised, version < 4 {
        let (decoded, escapes) = UnsyncEscapes.decode(try reader.bytes(body).array)
        area.decoded = Bytes(decoded, base: body.lowerBound, escapes: escapes)
        area.range = 0..<decoded.count
    }
    var cursor = area.range.lowerBound
    if flags & 0x40 != 0, version >= 3 {
        cursor += try extendedHeaderSize(area, at: cursor, version: version)
    }

    var tags = TrackTags()
    var pictures: [(type: UInt32, art: EmbeddedArt)] = []
    var day: (text: String, offset: Int)?
    var time: (text: String, offset: Int)?
    let headerSize = version == 2 ? 6 : 10
    let idLength = version == 2 ? 3 : 4
    while area.range.upperBound - cursor >= headerSize {
        try reader.step(at: area.fileOffset(cursor))
        let frameHeader = try area.bytes(cursor..<cursor + headerSize)
        if try frameHeader.uint8(0) == 0 { break }  // padding
        let id = latin1(try frameHeader.slice(0..<idLength).array)
        guard isFrameID(try frameHeader.slice(0..<idLength)) else {
            // Without a valid ID the size can't be trusted either, so nothing after it can be.
            reader.warn(
                .unreadableField, at: area.fileOffset(cursor),
                "invalid ID3v2 frame ID \"\(id)\"; the rest of the tag is skipped")
            break
        }
        let frameStart = cursor + headerSize
        let frameSize: Int
        switch version {
        case 2: frameSize = Int(try frameHeader.uint24BE(3))
        case 3: frameSize = Int(try frameHeader.uint32BE(4))
        default:
            frameSize = try id3v24FrameSize(
                frameHeader, id, area, frameStart: frameStart, at: area.fileOffset(cursor + 4),
                reader)
        }
        guard frameSize <= area.range.upperBound - frameStart else {
            throw .malformed(
                at: area.fileOffset(cursor),
                "ID3v2 frame \(id) of \(frameSize) bytes runs past the end of its tag")
        }
        let frame = frameStart..<frameStart + frameSize
        cursor = frame.upperBound
        guard let kind = frameKinds[id] else { continue }

        // The frame lies inside the tag, so damage within it spoils only this field.
        reader.skippingUnreadableField(at: area.fileOffset(frameStart - headerSize)) {
            () throws(ParseFailure) in
            var data = frame.lowerBound
            var frameUnsynchronised = false
            if version >= 3 {
                let format = try frameHeader.uint8(9)
                let (compressed, encrypted, grouped): (UInt8, UInt8, UInt8) =
                    version == 3 ? (0x80, 0x40, 0x20) : (0x08, 0x04, 0x40)
                if format & (compressed | encrypted) != 0 {
                    throw .unsupported(
                        at: area.fileOffset(frame.lowerBound - headerSize),
                        "compressed or encrypted ID3v2 frame \(id) skipped")
                }
                if format & grouped != 0 { data += 1 }
                if version == 4 {
                    if format & 0x01 != 0 { data += 4 }  // data length indicator
                    frameUnsynchronised = format & 0x02 != 0 || tagUnsynchronised
                }
            }
            guard data <= frame.upperBound else {
                throw .malformed(
                    at: area.fileOffset(frame.lowerBound), "ID3v2 frame \(id) is too short")
            }
            let contents = data..<frame.upperBound
            if case .picture = kind {
                if let picture = try picture(
                    area, contents, version: version, unsynchronised: frameUnsynchronised,
                    stored: tagUnsynchronised || frameUnsynchronised, &reader.warnings)
                {
                    pictures.append(picture)
                }
                return
            }

            var bytes = try area.bytes(contents)
            if frameUnsynchronised {
                let (decoded, escapes) = UnsyncEscapes.decode(bytes.array)
                bytes = Bytes(decoded, base: area.fileOffset(contents.lowerBound), escapes: escapes)
            }
            let offset = bytes.fileOffset(0)
            let field: TagField
            let text: String?
            switch kind {
            case .text(let textField):
                field = textField
                text = try textFrame(bytes, &reader.warnings)
            case .genre:
                field = .genre
                text = try genre(try textFrame(bytes, &reader.warnings), version, at: offset)
            case .comment:
                field = .comment
                text = try commentFrame(bytes, &reader.warnings)
            case .day:
                if day == nil { day = (try textFrame(bytes, &reader.warnings), offset) }
                return
            case .time:
                if time == nil { time = (try textFrame(bytes, &reader.warnings), offset) }
                return
            case .picture: return
            }
            if let text { tags.set(field, text, at: offset, warnings: &reader.warnings) }
        }
    }
    if let day, let year = tags.date {
        tags.date = fullDate(year: year, day: day, time: time, &reader.warnings)
    }
    return ID3v2Tag(tags: tags, art: preferredPicture(pictures), byteCount: byteCount)
}

/// Four characters from A–Z and 0–9.
private func isFrameID(_ bytes: Bytes) -> Bool {
    bytes.array.allSatisfy { (0x41...0x5A).contains($0) || (0x30...0x39).contains($0) }
}

/// A 2.4 frame size is syncsafe, but older iTunes wrote plain integers. Use the syncsafe reading
/// when it lands on the next frame, padding or the end of the tag; otherwise use the plain reading
/// if that does, with a warning.
private func id3v24FrameSize(
    _ header: Bytes, _ id: String, _ area: FrameArea, frameStart: Int, at offset: Int,
    _ reader: ByteReader
) throws(ParseFailure) -> Int {
    let syncsafe = try header.syncsafe(4)
    let plain = Int(try header.uint32BE(4))
    if let syncsafe {
        if syncsafe == plain { return syncsafe }
        if try landsOnFrame(area, frameStart + syncsafe) { return syncsafe }
    }
    if try landsOnFrame(area, frameStart + plain) {
        reader.warn(
            .nonSyncsafeFrameSize, at: offset,
            "ID3v2.4 frame \(id) size is a plain integer, not syncsafe")
        return plain
    }
    guard let syncsafe else {
        throw .malformed(at: offset, "ID3v2.4 frame \(id) size isn't syncsafe")
    }
    return syncsafe
}

/// Whether a frame ending at `position` is followed by the end of the tag, padding, or another
/// frame's ID.
private func landsOnFrame(_ area: FrameArea, _ position: Int) throws(ParseFailure) -> Bool {
    guard position < area.range.upperBound else { return position == area.range.upperBound }
    let next = try area.bytes(position..<min(area.range.upperBound, position + 4))
    if try next.uint8(0) == 0 { return true }
    return next.count == 4 && isFrameID(next)
}

/// 2.3 gives the size after its own four bytes; 2.4 gives a syncsafe size that includes them.
private func extendedHeaderSize(_ area: FrameArea, at cursor: Int, version: UInt8)
    throws(ParseFailure) -> Int
{
    let bytes = try area.bytes(cursor..<min(area.range.upperBound, cursor + 4))
    let size: Int
    if version == 3 {
        size = 4 + Int(try bytes.uint32BE(0))
    } else {
        guard let syncsafe = try bytes.syncsafe(0), syncsafe >= 6 else {
            throw .malformed(at: area.fileOffset(cursor), "ID3v2.4 extended header size is invalid")
        }
        size = syncsafe
    }
    guard size <= area.range.upperBound - cursor else {
        throw .malformed(
            at: area.fileOffset(cursor),
            "ID3v2 extended header of \(size) bytes runs past the end of its tag")
    }
    return size
}

private func encoding(_ byte: UInt8, at offset: Int) throws(ParseFailure) -> TextEncoding {
    switch byte {
    case 0: .latin1
    case 1: .utf16WithBOM
    case 2: .utf16BigEndian
    case 3: .utf8
    default: throw .malformed(at: offset, "ID3v2 text encoding \(byte)")
    }
}

private func terminator(_ encoding: TextEncoding) -> [UInt8] {
    switch encoding {
    case .utf16WithBOM, .utf16BigEndian: [0, 0]
    case .latin1, .utf8: [0]
    }
}

/// The string in `bytes` from `offset` to its terminator or the end, and where the next field
/// starts. Nil when `requireTerminator` and there's none.
private func string(
    _ bytes: Bytes, from offset: Int, _ encoding: TextEncoding,
    _ warnings: inout [MetadataWarning], requireTerminator: Bool = false
) throws(ParseFailure) -> (text: String, next: Int)? {
    let end = bytes.firstIndex(of: terminator(encoding), from: offset)
    if end == nil, requireTerminator { return nil }
    let stop = end ?? bytes.count
    let text = encoding.decode(
        try bytes.slice(offset..<max(offset, stop)).array, at: bytes.fileOffset(offset),
        warnings: &warnings)
    return (text, end.map { $0 + terminator(encoding).count } ?? bytes.count)
}

/// An encoding byte, then text. 2.4 separates several values with terminators; the first is used.
private func textFrame(_ bytes: Bytes, _ warnings: inout [MetadataWarning]) throws(ParseFailure)
    -> String
{
    let encoding = try encoding(try bytes.uint8(0), at: bytes.fileOffset(0))
    return try string(bytes, from: 1, encoding, &warnings)!.text
}

/// An encoding byte, a language, a description, then the text. Nil unless the description is
/// empty: players store their own data in described comments.
private func commentFrame(_ bytes: Bytes, _ warnings: inout [MetadataWarning])
    throws(ParseFailure) -> String?
{
    let encoding = try encoding(try bytes.uint8(0), at: bytes.fileOffset(0))
    guard let description = try string(bytes, from: 4, encoding, &warnings, requireTerminator: true)
    else {
        throw .malformed(at: bytes.fileOffset(0), "ID3v2 comment without a description terminator")
    }
    guard description.text.isEmpty else { return nil }
    return try string(bytes, from: description.next, encoding, &warnings)!.text
}

/// "(17)" refers to the ID3v1 list (the first of several references counts), optionally followed
/// by a refinement that wins; "((" escapes a
/// literal parenthesis; 2.4 also allows a bare number.
private func genre(_ text: String, _ version: UInt8, at offset: Int) throws(ParseFailure) -> String
{
    if text.hasPrefix("((") { return String(text.dropFirst()) }
    func named(_ reference: Substring) throws(ParseFailure) -> String {
        switch reference {
        case "RX": return "Remix"
        case "CR": return "Cover"
        default:
            guard let index = Int(reference), id3v1Genres.indices.contains(index) else {
                throw .malformed(at: offset, "ID3v2 genre reference \"\(reference)\"")
            }
            return id3v1Genres[index]
        }
    }
    var rest = Substring(text)
    var first: String?
    while rest.hasPrefix("("), !rest.hasPrefix("(("), let close = rest.firstIndex(of: ")") {
        let reference = try named(rest[rest.index(after: rest.startIndex)..<close])
        first = first ?? reference
        rest = rest[rest.index(after: close)...]
    }
    if let first { return rest.isEmpty ? first : String(rest) }
    // A bare number outside the ID3v1 list is the user's own genre text.
    if version == 4, let index = Int(text), text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber),
        id3v1Genres.indices.contains(index)
    {
        return id3v1Genres[index]
    }
    return text
}

/// `APIC`: an encoding byte, a MIME type, the picture type, a description, then the image.
/// ID3v2.2's `PIC` has a three-letter format instead of the MIME type. Only the header is read;
/// the image is recorded by offset. Nil for an empty image or a link.
private func picture(
    _ area: FrameArea, _ contents: Range<Int>, version: UInt8, unsynchronised: Bool, stored: Bool,
    _ warnings: inout [MetadataWarning]
) throws(ParseFailure) -> (type: UInt32, art: EmbeddedArt)? {
    func header(_ length: Int) throws(ParseFailure) -> Bytes {
        let raw = try area.bytes(contents.lowerBound..<contents.lowerBound + length)
        guard unsynchronised else { return raw }
        let (decoded, escapes) = UnsyncEscapes.decode(raw.array)
        return Bytes(decoded, base: area.fileOffset(contents.lowerBound), escapes: escapes)
    }
    var bytes = try header(min(contents.count, pictureHeaderBytes))
    var parsed = try pictureHeader(bytes, version: version, &warnings)
    if parsed == nil, contents.count > pictureHeaderBytes {
        bytes = try header(contents.count)
        parsed = try pictureHeader(bytes, version: version, &warnings)
    }
    guard let (mime, type, imageStart) = parsed else {
        throw .malformed(
            at: area.fileOffset(contents.lowerBound), "ID3v2 picture frame header is cut off")
    }
    guard mime != linkedPictureMIMEType else { return nil }
    let offset = bytes.fileOffset(imageStart)
    let end = area.fileOffset(contents.upperBound - 1) + 1
    guard end > offset else { return nil }
    return (
        type,
        EmbeddedArt(offset: offset, byteCount: end - offset, mimeType: mime, unsynchronised: stored)
    )
}

/// The MIME type, picture type and where the image starts, or nil when `bytes` ends first.
private func pictureHeader(_ bytes: Bytes, version: UInt8, _ warnings: inout [MetadataWarning])
    throws(ParseFailure)
    -> (String, UInt32, Int)?
{
    guard bytes.count >= 1 else { return nil }
    let encoding = try encoding(try bytes.uint8(0), at: bytes.fileOffset(0))
    let mime: String
    var cursor: Int
    if version == 2 {
        guard bytes.count >= 4 else { return nil }
        let format = latin1(try bytes.slice(1..<4).array)
        mime = ["JPG": jpegMIMEType, "PNG": pngMIMEType][format] ?? "image/\(format.lowercased())"
        cursor = 4
    } else {
        guard let found = try string(bytes, from: 1, .latin1, &warnings, requireTerminator: true)
        else {
            return nil
        }
        mime = found.text
        cursor = found.next
    }
    guard cursor < bytes.count else { return nil }
    let type = UInt32(try bytes.uint8(cursor))
    guard
        let description = try string(
            bytes, from: cursor + 1, encoding, &warnings, requireTerminator: true)
    else { return nil }
    return (mime, type, description.next)
}

/// A 2.3 year with its `TDAT` and `TIME`, as "1997-05-12T14:30". A day or time that isn't four
/// digits is dropped with a warning; a year that isn't four digits keeps its text.
private func fullDate(
    year: String, day: (text: String, offset: Int), time: (text: String, offset: Int)?,
    _ warnings: inout [MetadataWarning]
) -> String {
    func digits(_ text: String, _ ranges: (ClosedRange<Int>, ClosedRange<Int>)) -> (Int, Int)? {
        guard text.count == 4, text.allSatisfy({ $0.isASCII && $0.isNumber }),
            let first = Int(text.prefix(2)), let second = Int(text.suffix(2)),
            ranges.0.contains(first), ranges.1.contains(second)
        else { return nil }
        return (first, second)
    }
    guard year.count == 4, year.allSatisfy({ $0.isASCII && $0.isNumber }) else { return year }
    guard let (dayOfMonth, month) = digits(day.text, (1...31, 1...12)) else {
        warnings.append(
            MetadataWarning(
                kind: .badValue, offset: day.offset,
                detail: "TDAT \"\(day.text)\" isn't DDMM; the date is the year alone"))
        return year
    }
    func two(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
    var date = "\(year)-\(two(month))-\(two(dayOfMonth))"
    if let time {
        if let (hour, minute) = digits(time.text, (0...23, 0...59)) {
            date += "T\(two(hour)):\(two(minute))"
        } else {
            warnings.append(
                MetadataWarning(
                    kind: .badValue, offset: time.offset,
                    detail: "TIME \"\(time.text)\" isn't HHMM; ignored"))
        }
    }
    return date
}
