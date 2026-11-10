/// The first bytes of an ID3v2 tag.
package let id3v2Identifier = "ID3"

/// An ID3v2 tag's fields and art, and how many bytes the tag takes.
struct ID3v2Tag {
    var tags: TrackTags
    var art: EmbeddedArt?
    var pictures: [EmbeddedPicture]
    /// Header, extended header, frames, padding and footer.
    var byteCount: Int
}

private enum FrameKind {
    case text(TagField)
    /// `TCON`, which may refer to the ID3v1 list.
    case genre
    /// `COMM` or `USLT`: a language and a description before the text. Only the one with an
    /// empty description is the user's; players store their own data in described ones.
    case described(TagField)
    /// A `W` frame: Latin-1 text with no encoding byte.
    case url(TagField)
    case picture
    /// 2.3's `TDAT` (DDMM) and `TIME` (HHMM), which refine `TYER` into a full date.
    case day, time
    /// `TXXX`: a description naming the field, then its value.
    case userText
    /// `WXXX`: a description naming the link, then a Latin-1 URL. Read as a custom key.
    case userURL
    /// `TIPL`, or 2.3's `IPLS`: roles and names in turn. Read as a custom key.
    case involvedPeople
    /// iTunes's `GRP1`, which wins over `TIT1`: iTunes and Picard's iTunes option put the work in
    /// `TIT1` once `GRP1` holds the grouping.
    case iTunesGrouping
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
    package static let grouping = "TIT1"
    /// iTunes's grouping, which wins over `TIT1` when a tag has both.
    package static let iTunesGrouping = "GRP1"
}

/// Where the tag writer writes a field in an ID3v2.3 or 2.4 tag. The reader reads each.
package enum ID3Key: Hashable, Sendable {
    /// A text frame: an encoding byte, then the text.
    case text(String)
    /// `TXXX` with this description.
    case userText(String)
    /// A frame with a language and an empty description before the text: `COMM` and `USLT`.
    case described(String)
    /// A URL frame: Latin-1 text with no encoding byte.
    case url(String)
}

/// The frame ID and how the reader reads it, for a key that's a frame of its own.
private func frameKind(_ key: ID3Key, _ field: TagField) -> (String, FrameKind)? {
    switch key {
    case .text(let id): (id, .text(field))
    case .described(let id): (id, .described(field))
    case .url(let id): (id, .url(field))
    case .userText: nil
    }
}

/// The frame each field is written as in 2.4, and in 2.3 unless `id3v23WrittenKeys` names it. A
/// 2.3 date is split across `TYER`, `TDAT` and `TIME` by the writer.
private let id3WrittenKeys: [TagField: ID3Key] = [
    .title: .text(ID3FrameID.title), .artist: .text(ID3FrameID.artist),
    .album: .text(ID3FrameID.album), .albumArtist: .text(ID3FrameID.albumArtist),
    .genre: .text(ID3FrameID.genre), .date: .text(ID3FrameID.date),
    .track: .text(ID3FrameID.track), .disc: .text(ID3FrameID.disc),
    .compilation: .text(ID3FrameID.compilation), .composer: .text(ID3FrameID.composer),
    .comment: .described(ID3FrameID.comment), .grouping: .text(ID3FrameID.grouping),
    .catalogNumber: .userText(SharedTagName.catalogNumber),
    .barcode: .userText(SharedTagName.barcode), .bpm: .text("TBPM"), .key: .text("TKEY"),
    .conductor: .text("TPE3"), .lyricist: .text("TEXT"), .publisher: .text("TPUB"),
    .copyright: .text("TCOP"), .encoder: .text("TENC"),
    .description: .userText(SharedTagName.description), .discSubtitle: .text("TSST"),
    .work: .userText(SharedTagName.work), .movement: .text("MVIN"),
    .movementName: .text("MVNM"), .originalDate: .text("TDOR"), .titleSort: .text("TSOT"),
    .artistSort: .text("TSOP"), .albumSort: .text("TSOA"), .albumArtistSort: .text("TSO2"),
    .composerSort: .text("TSOC"), .remixer: .text("TPE4"), .originalArtist: .text("TOPE"),
    .originalAlbum: .text("TOAL"), .isrc: .text("TSRC"), .language: .text("TLAN"),
    .mood: .text("TMOO"), .media: .text("TMED"), .lyrics: .described("USLT"),
    .artistURL: .url("WOAR"), .audioFileURL: .url("WOAF"), .audioSourceURL: .url("WOAS"),
    .commercialURL: .url("WCOM"), .copyrightURL: .url("WCOP"), .paymentURL: .url("WPAY"),
    .publisherURL: .url("WPUB"), .radioStationURL: .url("WORS"),
]

/// 2.3's spelling of fields whose frames are 2.4's alone, as Picard writes them. An original date
/// that is a year goes in `TORY`, which the writer decides.
private let id3v23WrittenKeys: [TagField: ID3Key] = [
    .discSubtitle: .userText(SharedTagName.discSubtitle), .mood: .userText(SharedTagName.mood),
    .originalDate: .userText(SharedTagName.originalDate),
]

/// The key the tag writer writes `field` as in a tag of `version`; nil for none. The movement's
/// total shares `.movement`'s frame, as the track's does `.track`'s.
package func id3WrittenKey(for field: TagField, version: UInt8) -> ID3Key? {
    (version == 3 ? id3v23WrittenKeys[field] : nil) ?? id3WrittenKeys[field]
}

/// ID3v2.2 has three-character IDs, 2.3 and 2.4 four. `TDRC` is 2.4's date and `TYER` 2.3's year;
/// taggers mix them, so both are read in every version. The written frames come first, then
/// other spellings of the same fields.
private let frameKinds: [String: FrameKind] = Dictionary(
    uniqueKeysWithValues: (Array(id3WrittenKeys) + Array(id3v23WrittenKeys)).compactMap {
        field, key in frameKind(key, field)
    }
).merging(
    [
        "TT2": .text(.title), "TP1": .text(.artist), "TAL": .text(.album),
        "TP2": .text(.albumArtist), "TCO": .genre, "TYE": .text(.date), "TRK": .text(.track),
        "TPA": .text(.disc), "TCP": .text(.compilation), "TCM": .text(.composer),
        "COM": .described(.comment), "PIC": .picture, ID3FrameID.genre: .genre,
        id3v23YearFrameID: .text(.date), "APIC": .picture, id3v23DayFrameID: .day,
        id3v23TimeFrameID: .time, "TT1": .text(.grouping), "TBP": .text(.bpm),
        "TKE": .text(.key), "TP3": .text(.conductor), "TXT": .text(.lyricist),
        "TPB": .text(.publisher), "TCR": .text(.copyright), "TEN": .text(.encoder),
        "TOR": .text(.originalDate), "TXX": .userText, ID3FrameID.iTunesGrouping: .iTunesGrouping,
        id3v23OriginalYearFrameID: .text(.originalDate), id3UserTextFrameID: .userText,
        "WXX": .userURL, id3UserURLFrameID: .userURL, "IPL": .involvedPeople,
        id3InvolvedPeopleFrameID(version: 3): .involvedPeople,
        id3InvolvedPeopleFrameID(version: 4): .involvedPeople,
    ],
    // The genre's frame is read as a genre, which may refer to the ID3v1 list.
    uniquingKeysWith: { _, other in other })

/// `TXXX` descriptions, compared uppercased, and the fields they set.
private let userTextFields: [String: TagField] = Dictionary(
    uniqueKeysWithValues: (Array(id3WrittenKeys) + Array(id3v23WrittenKeys)).compactMap {
        field, key in
        if case .userText(let description) = key { (description, field) } else { nil }
    })

/// The `TXXX` descriptions, uppercased, the reader maps onto `field`, so a writer replaces
/// exactly those.
package func id3UserTextDescriptions(for field: TagField) -> Set<String> {
    userTextDescriptionsByField[field] ?? []
}

private let userTextDescriptionsByField = keysByField(userTextFields.map { ($0.key, $0.value) })

/// 2.3's original release year, which 2.4 replaced with `TDOR`.
package let id3v23OriginalYearFrameID = "TORY"

/// User-defined text: a description naming the field, then its value.
package let id3UserTextFrameID = "TXXX"

/// A user-defined link: a description, then a Latin-1 URL.
package let id3UserURLFrameID = "WXXX"

/// The involved people list in a tag of `version`: 2.4's `TIPL`, which replaced 2.3's `IPLS`.
package func id3InvolvedPeopleFrameID(version: UInt8) -> String {
    version == 3 ? "IPLS" : "TIPL"
}

/// ID3v2.3 holds a date as `TYER`, `TDAT` and `TIME`.
package let id3v23YearFrameID = "TYER"
package let id3v23DayFrameID = "TDAT"
package let id3v23TimeFrameID = "TIME"

/// The frame IDs the reader maps onto `field`, so a writer replaces exactly those.
package func id3FrameIDs(for field: TagField) -> Set<String> { frameIDsByField[field] ?? [] }

private let frameIDsByField = keysByField(
    frameKinds.compactMap { id, kind -> (String, TagField)? in
        switch kind {
        case .text(let each), .described(let each), .url(let each): (id, each)
        case .genre: (id, .genre)
        case .day, .time: (id, .date)
        case .iTunesGrouping: (id, .grouping)
        case .picture, .userText, .userURL, .involvedPeople: nil
        }
    })

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
    var pictures: [EmbeddedPicture] = []
    var day: (text: String, offset: Int)?
    var time: (text: String, offset: Int)?
    var iTunes = TrackTags()
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
            case .described(let describedField):
                field = describedField
                text = try commentFrame(bytes, &reader.warnings)
            case .url(let urlField):
                field = urlField
                text = latin1(bytes.array.prefix { $0 != 0 })
            case .day:
                if day == nil { day = (try textFrame(bytes, &reader.warnings), offset) }
                return
            case .time:
                if time == nil { time = (try textFrame(bytes, &reader.warnings), offset) }
                return
            case .iTunesGrouping:
                let text = try textFrame(bytes, &reader.warnings)
                iTunes.set(.grouping, text, at: offset, warnings: &reader.warnings)
                return
            case .userText:
                let (description, value) = try userTextFrame(bytes, &reader.warnings)
                guard let userField = userTextFields[description.uppercased()] else {
                    tags.setCustom(description, value, at: offset, warnings: &reader.warnings)
                    return
                }
                field = userField
                text = value
            case .userURL:
                let (description, url) = try userURLFrame(bytes, &reader.warnings)
                tags.setCustom(
                    ID3CustomKey.url(description), url, at: offset, warnings: &reader.warnings)
                return
            case .involvedPeople:
                let values = try textFrameValues(bytes, &reader.warnings)
                tags.setCustom(
                    ID3CustomKey.involvedPeople,
                    values.joined(separator: ID3CustomKey.involvedPeopleSeparator), at: offset,
                    warnings: &reader.warnings)
                return
            case .picture: return
            }
            if let text { tags.set(field, text, at: offset, warnings: &reader.warnings) }
        }
    }
    tags.grouping = iTunes.grouping ?? tags.grouping
    if let day, let year = tags.date {
        tags.date = fullDate(year: year, day: day, time: time, &reader.warnings)
    }
    return ID3v2Tag(
        tags: tags, art: preferredPicture(pictures), pictures: reader.kept(pictures),
        byteCount: byteCount)
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

/// `bytes` read in the encoding an ID3 encoding byte names, as the reader reads a description,
/// for the tag writer to match a `TXXX` by; nil for an unknown encoding.
package func id3Decoded(_ bytes: [UInt8], encoding byte: UInt8) -> String? {
    var warnings: [MetadataWarning] = []
    return (try? encoding(byte, at: 0))?.decode(bytes, at: 0, warnings: &warnings)
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

/// An encoding byte, then every value, as an involved people list holds its roles and names.
/// A terminator after the last value doesn't make an empty one.
private func textFrameValues(_ bytes: Bytes, _ warnings: inout [MetadataWarning])
    throws(ParseFailure) -> [String]
{
    let encoding = try encoding(try bytes.uint8(0), at: bytes.fileOffset(0))
    var values: [String] = []
    var cursor = 1
    while cursor < bytes.count {
        let (text, next) = try string(bytes, from: cursor, encoding, &warnings)!
        values.append(text)
        cursor = next
    }
    return values
}

/// An encoding byte, a description, then a Latin-1 URL up to a NUL or the end.
private func userURLFrame(_ bytes: Bytes, _ warnings: inout [MetadataWarning])
    throws(ParseFailure) -> (description: String, url: String)
{
    let encoding = try encoding(try bytes.uint8(0), at: bytes.fileOffset(0))
    guard let description = try string(bytes, from: 1, encoding, &warnings, requireTerminator: true)
    else {
        throw .malformed(at: bytes.fileOffset(0), "ID3v2 WXXX without a description terminator")
    }
    let url = latin1(try bytes.slice(description.next..<bytes.count).array.prefix { $0 != 0 })
    return (description.text, url)
}

/// An encoding byte, a description, then the value. 2.4's further values are left out, as in
/// `textFrame`.
private func userTextFrame(_ bytes: Bytes, _ warnings: inout [MetadataWarning])
    throws(ParseFailure) -> (description: String, value: String)
{
    let encoding = try encoding(try bytes.uint8(0), at: bytes.fileOffset(0))
    guard let description = try string(bytes, from: 1, encoding, &warnings, requireTerminator: true)
    else {
        throw .malformed(at: bytes.fileOffset(0), "ID3v2 TXXX without a description terminator")
    }
    let value = try string(bytes, from: description.next, encoding, &warnings)!.text
    return (description.text, value)
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
) throws(ParseFailure) -> EmbeddedPicture? {
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
    return EmbeddedPicture(
        art: EmbeddedArt(
            offset: offset, byteCount: end - offset, mimeType: mime, unsynchronised: stored),
        type: PictureType(rawValue: type))
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
