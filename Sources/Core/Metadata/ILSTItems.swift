/// What the iTunes metadata items under `moov/udta/meta/ilst` hold.
struct ILSTItems {
    var tags = TrackTags()
    /// The first picture of the first `covr`.
    var art: EmbeddedArt?
    var pictures: [EmbeddedPicture] = []
    /// From `iTunSMPB`: AAC's length without the encoder's priming and remainder frames.
    var gaplessLength: Int?
}

private enum ItemKind {
    case text(TagField)
    /// A big-endian integer of 1 to 8 bytes, set as `TagField` text.
    case integer(TagField)
    case track, disc, compilation
    /// The ID3v1 genre index plus one.
    case genreIndex
    /// `----`, named by its `mean` and `name` atoms.
    case freeform
    case cover
}

/// The `ilst` item types the reader and the tag writer both name.
package enum MP4ItemType {
    package static let title = "\u{A9}nam"
    package static let artist = "\u{A9}ART"
    package static let album = "\u{A9}alb"
    package static let albumArtist = "aART"
    package static let genre = "\u{A9}gen"
    package static let date = "\u{A9}day"
    package static let composer = "\u{A9}wrt"
    package static let comment = "\u{A9}cmt"
    package static let track = "trkn"
    package static let disc = "disk"
    package static let compilation = "cpil"
    package static let freeform = "----"
}

/// Where the tag writer writes a field in `ilst`. The reader reads each.
package enum MP4Key: Hashable, Sendable {
    /// An item by type: text, or a big-endian integer for a field that isn't text.
    case item(String)
    /// An iTunes freeform item (`----`, `mean` com.apple.iTunes) by `name`, holding text.
    case freeform(String)
}

/// The item each text or number field is written as. A track, disc and compilation have item
/// kinds of their own, in `itemKinds`.
private let mp4WrittenKeys: [TagField: MP4Key] = [
    .title: .item(MP4ItemType.title), .artist: .item(MP4ItemType.artist),
    .album: .item(MP4ItemType.album), .albumArtist: .item(MP4ItemType.albumArtist),
    .genre: .item(MP4ItemType.genre), .date: .item(MP4ItemType.date),
    .composer: .item(MP4ItemType.composer), .comment: .item(MP4ItemType.comment),
    .grouping: .item("\u{A9}grp"), .copyright: .item("cprt"), .encoder: .item("\u{A9}too"),
    .description: .item("desc"), .work: .item("\u{A9}wrk"), .movementName: .item("\u{A9}mvn"),
    .bpm: .item("tmpo"), .movement: .item("\u{A9}mvi"), .movementTotal: .item("\u{A9}mvc"),
    .titleSort: .item("sonm"), .artistSort: .item("soar"), .albumSort: .item("soal"),
    .albumArtistSort: .item("soaa"), .composerSort: .item("soco"), .lyrics: .item("\u{A9}lyr"),
    .catalogNumber: .freeform(SharedTagName.catalogNumber),
    .barcode: .freeform(SharedTagName.barcode),
    // Picard's spelling; names are compared uppercased.
    .key: .freeform("initialkey"), .conductor: .freeform(SharedTagName.conductor),
    .lyricist: .freeform(SharedTagName.lyricist), .publisher: .freeform(SharedTagName.label),
    .discSubtitle: .freeform(SharedTagName.discSubtitle),
    .originalDate: .freeform(SharedTagName.originalDate),
    .remixer: .freeform(SharedTagName.remixer),
    .originalArtist: .freeform(SharedTagName.originalArtist),
    .originalAlbum: .freeform(SharedTagName.originalAlbum), .isrc: .freeform(SharedTagName.isrc),
    .language: .freeform(SharedTagName.language), .mood: .freeform(SharedTagName.mood),
    .media: .freeform(SharedTagName.media), .artistURL: .freeform(SharedTagName.artistURL),
    .audioFileURL: .freeform(SharedTagName.audioFileURL),
    .audioSourceURL: .freeform(SharedTagName.audioSourceURL),
    .commercialURL: .freeform(SharedTagName.commercialURL),
    .copyrightURL: .freeform(SharedTagName.copyrightURL),
    .paymentURL: .freeform(SharedTagName.paymentURL),
    .publisherURL: .freeform(SharedTagName.publisherURL),
    .radioStationURL: .freeform(SharedTagName.radioStationURL),
]

/// The key the tag writer writes `field` as; nil for the track, disc and compilation, which
/// have items of their own.
package func mp4WrittenKey(for field: TagField) -> MP4Key? { mp4WrittenKeys[field] }

private let itemKinds: [String: ItemKind] = Dictionary(
    uniqueKeysWithValues: mp4WrittenKeys.compactMap { field, key in
        guard case .item(let type) = key else { return nil }
        return (type, field.textProperty == nil ? ItemKind.integer(field) : .text(field))
    }
).merging(
    [
        MP4ItemType.track: .track, MP4ItemType.disc: .disc,
        MP4ItemType.compilation: .compilation, "gnre": .genreIndex,
        MP4ItemType.freeform: .freeform, "covr": .cover,
    ],
    uniquingKeysWith: { written, _ in written })

/// The `mean` of the iTunes freeform items.
package let iTunesMean = "com.apple.iTunes"

/// The freeform item iTunes keeps AAC's gapless length in, which isn't a custom key.
package let iTunesGaplessName = "iTunSMPB"

/// iTunes freeform item names, compared uppercased, and the fields they set.
private let freeformFields: [String: TagField] = Dictionary(
    uniqueKeysWithValues: mp4WrittenKeys.compactMap { field, key in
        if case .freeform(let name) = key { (name.uppercased(), field) } else { nil }
    })

/// The freeform names, uppercased, the reader maps onto `field`, so a writer replaces exactly
/// those.
package func mp4FreeformNames(for field: TagField) -> Set<String> {
    freeformNamesByField[field] ?? []
}

private let freeformNamesByField = keysByField(freeformFields.map { ($0.key, $0.value) })

/// `data` atom type codes for integers: "implicit" and big-endian signed.
private let integerTypes: Set<UInt32> = [0, 21]

/// The item types the reader maps onto `field`, so a writer replaces exactly those.
package func mp4ItemTypes(for field: TagField) -> Set<String> { itemTypesByField[field] ?? [] }

private let itemTypesByField = keysByField(
    itemKinds.compactMap { type, kind -> (String, TagField)? in
        switch kind {
        case .text(let each), .integer(let each): (type, each)
        case .track: (type, .track)
        case .disc: (type, .disc)
        case .compilation: (type, .compilation)
        case .genreIndex: (type, .genre)
        case .freeform, .cover: nil
        }
    })

/// The item the reader takes art from.
package let mp4CoverItemType = itemKinds.first {
    if case .cover = $0.value { true } else { false }
}!.key

private let bmpMIMEType = "image/bmp"

/// `data` atom type codes for cover art. Type 0 is "implicit", so the image is sniffed.
package let mp4ArtTypes: [UInt32: String] = [
    12: gifMIMEType, 13: jpegMIMEType, 14: pngMIMEType, 27: bmpMIMEType,
]

/// The image format a picture's first bytes announce, for covers whose type code says nothing.
private func sniffedMIMEType(_ head: [UInt8]) -> String? {
    if head.starts(with: [0xFF, 0xD8, 0xFF]) { return jpegMIMEType }
    if head.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return pngMIMEType }
    if head.starts(with: Array("GIF8".utf8)) { return gifMIMEType }
    if head.starts(with: Array("BM".utf8)) { return bmpMIMEType }
    return nil
}

/// The items in `udta`. `meta` is a full box in iTunes files, with four bytes of version and flags
/// before its children; QuickTime writes it without them.
func metadataItems(_ reader: ByteReader, _ udta: Atom) throws(ParseFailure) -> ILSTItems {
    var items = ILSTItems()
    try forEachAtom(reader, in: udta.body, parent: udta) { meta throws(ParseFailure) in
        guard meta.type == MP4Type.meta else { return true }
        let first = meta.body.lowerBound..<min(meta.body.upperBound, meta.body.lowerBound + 4)
        let isFullBox = try reader.bytes(first).uint32BE(0) == 0
        let children = (meta.body.lowerBound + (isFullBox ? 4 : 0))..<meta.body.upperBound
        try forEachAtom(reader, in: children, parent: meta) { ilst throws(ParseFailure) in
            guard ilst.type == MP4Type.ilst else { return true }
            try forEachAtom(reader, in: ilst.body, parent: ilst) { item throws(ParseFailure) in
                // The item is inside `ilst`, so damage within it spoils only that field.
                reader.skippingUnreadableField(at: item.start) { () throws(ParseFailure) in
                    try read(item, reader, into: &items)
                }
                return true
            }
            return false
        }
        return false
    }
    return items
}

/// A `data` atom's type code and where its value lies.
private func dataValue(_ data: Atom, of item: Atom, _ reader: ByteReader) throws(ParseFailure)
    -> (type: UInt32, value: Range<Int>)
{
    guard data.body.count >= 8 else {
        throw .malformed(at: data.start, "MP4 '\(item.type)' data atom is too short")
    }
    let header = try reader.bytes(data.body.lowerBound..<data.body.lowerBound + 8)
    return (try header.uint32BE(0) & 0xFF_FFFF, data.body.lowerBound + 8..<data.body.upperBound)
}

/// An item holds a `data` atom: a type code, a locale, then the value. Freeform items also hold
/// `mean` and `name`. Unknown items are skipped without reading their values.
private func read(_ item: Atom, _ reader: ByteReader, into items: inout ILSTItems)
    throws(ParseFailure)
{
    guard let kind = itemKinds[item.type] else { return }
    var datas: [Atom] = []
    var mean: String?
    var name: String?
    try forEachAtom(reader, in: item.body, parent: item) { child throws(ParseFailure) in
        switch child.type {
        case MP4Type.data: datas.append(child)
        case MP4Type.mean: mean = latin1(try reader.bytes(child.body).suffix(from: 4).array)
        case MP4Type.name: name = latin1(try reader.bytes(child.body).suffix(from: 4).array)
        default: break
        }
        return true
    }
    // `covr` holds a `data` atom a picture; every other item, one value.
    // A picture of a type it can't show is left out and the rest kept; only a `covr` with
    // none it can show is reported, as one of a single picture always was.
    if case .cover = kind {
        // Without the pictures kept, the first one it can show is all a scan needs.
        guard reader.keepsPictures || items.art == nil else { return }
        var skipped: ParseFailure?
        for data in datas {
            let (type, valueRange) = try dataValue(data, of: item, reader)
            let offset = valueRange.lowerBound
            let head = try reader.bytes(offset..<min(valueRange.upperBound, offset + 8))
            guard let mime = mp4ArtTypes[type] ?? (type == 0 ? sniffedMIMEType(head.array) : nil)
            else {
                skipped =
                    skipped ?? .unsupported(at: data.start, "MP4 cover art with data type \(type)")
                continue
            }
            let art = EmbeddedArt(
                offset: offset, byteCount: valueRange.count, mimeType: mime, unsynchronised: false)
            if items.art == nil { items.art = art }
            guard reader.keepsPictures else { break }
            items.pictures.append(EmbeddedPicture(art: art, type: nil))
        }
        if items.art == nil, let skipped { throw skipped }
        return
    }
    guard let data = datas.first else { return }
    let (type, valueRange) = try dataValue(data, of: item, reader)
    let offset = valueRange.lowerBound

    let value = try reader.bytes(valueRange)
    switch kind {
    case .text(let field):
        let text = try text(value, type, at: offset, &reader.warnings)
        items.tags.set(field, text, at: offset, warnings: &reader.warnings)
    case .integer(let field):
        guard integerTypes.contains(type), (1...8).contains(value.count) else {
            throw .malformed(
                at: offset,
                "MP4 '\(item.type)' isn't an integer (type \(type), \(value.count) bytes)")
        }
        let number = value.array.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        items.tags.set(field, String(number), at: offset, warnings: &reader.warnings)
    case .track, .disc:
        // Two reserved bytes, the number, the total, and for trkn two more reserved bytes.
        let number = Int(try value.uint16BE(2))
        let total = Int(try value.uint16BE(4))
        if case .track = kind {
            items.tags.trackNumber = items.tags.trackNumber ?? (number == 0 ? nil : number)
            items.tags.trackTotal = items.tags.trackTotal ?? (total == 0 ? nil : total)
        } else {
            items.tags.discNumber = items.tags.discNumber ?? (number == 0 ? nil : number)
            items.tags.discTotal = items.tags.discTotal ?? (total == 0 ? nil : total)
        }
    case .compilation:
        items.tags.compilation = items.tags.compilation || value.array.contains { $0 != 0 }
    case .genreIndex:
        let index = Int(try value.uint16BE(0)) - 1
        guard id3v1Genres.indices.contains(index) else {
            throw .malformed(at: offset, "MP4 gnre \(index + 1) isn't an ID3v1 genre")
        }
        items.tags.set(.genre, id3v1Genres[index], at: offset, warnings: &reader.warnings)
    case .freeform:
        guard mean == iTunesMean, let name else { return }
        if name == iTunesGaplessName {
            let text = try text(value, type, at: offset, &reader.warnings)
            items.gaplessLength = try gaplessLength(text, at: offset)
        } else if let field = freeformFields[name.uppercased()] {
            let text = try text(value, type, at: offset, &reader.warnings)
            items.tags.set(field, text, at: offset, warnings: &reader.warnings)
        } else if textTypes[type] != nil {
            // Other players keep binary data in freeform items of their own; only text is a field.
            let text = try text(value, type, at: offset, &reader.warnings)
            items.tags.setCustom(name, text, at: offset, warnings: &reader.warnings)
        }
    case .cover:
        break
    }
}

/// `data` atom type codes for text, and its encoding.
private let textTypes: [UInt32: TextEncoding] = [1: .utf8, 2: .utf16BigEndian]

private func text(
    _ value: Bytes, _ type: UInt32, at offset: Int, _ warnings: inout [MetadataWarning]
) throws(ParseFailure) -> String {
    guard let encoding = textTypes[type] else {
        throw .malformed(at: offset, "MP4 text item with data type \(type)")
    }
    return encoding.decode(value.array, at: offset, warnings: &warnings)
}

/// `iTunSMPB` is hex fields separated by spaces: a zero, the priming frames, the remainder frames,
/// then the length in frames.
private func gaplessLength(_ text: String, at offset: Int) throws(ParseFailure) -> Int {
    let fields = text.split(separator: " ")
    guard fields.count >= 4, let length = Int(fields[3], radix: 16), length > 0 else {
        throw .malformed(at: offset, "iTunSMPB \"\(text)\" has no length")
    }
    return length
}
