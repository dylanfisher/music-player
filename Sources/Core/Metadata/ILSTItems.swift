/// What the iTunes metadata items under `moov/udta/meta/ilst` hold.
struct ILSTItems {
    var tags = TrackTags()
    var art: EmbeddedArt?
    /// From `iTunSMPB`: AAC's length without the encoder's priming and remainder frames.
    var gaplessLength: Int?
}

private enum ItemKind {
    case text(TagField)
    case track, disc, compilation
    /// The ID3v1 genre index plus one.
    case genreIndex
    /// `----`, named by its `mean` and `name` atoms.
    case freeform
    case cover
}

private let itemKinds: [String: ItemKind] = [
    "\u{A9}nam": .text(.title), "\u{A9}ART": .text(.artist), "\u{A9}alb": .text(.album),
    "aART": .text(.albumArtist), "\u{A9}gen": .text(.genre), "\u{A9}day": .text(.date),
    "\u{A9}wrt": .text(.composer), "\u{A9}cmt": .text(.comment), "trkn": .track, "disk": .disc,
    "cpil": .compilation, "gnre": .genreIndex, "----": .freeform, "covr": .cover,
]

/// The item types the reader maps onto `field`, so a writer replaces exactly those.
package func mp4ItemTypes(for field: TagField) -> Set<String> {
    Set(
        itemKinds.compactMap { type, kind in
            switch kind {
            case .text(let each): each == field ? type : nil
            case .track: field == .track ? type : nil
            case .disc: field == .disc ? type : nil
            case .compilation: field == .compilation ? type : nil
            case .genreIndex: field == .genre ? type : nil
            case .freeform, .cover: nil
            }
        })
}

/// The item the reader takes art from.
package let mp4CoverItemType = itemKinds.first {
    if case .cover = $0.value { true } else { false }
}!.key

private let bmpMIMEType = "image/bmp"

/// `data` atom type codes for cover art. Type 0 is "implicit", so the image is sniffed.
private let artTypes: [UInt32: String] = [
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
        guard meta.type == "meta" else { return true }
        let first = meta.body.lowerBound..<min(meta.body.upperBound, meta.body.lowerBound + 4)
        let isFullBox = try reader.bytes(first).uint32BE(0) == 0
        let children = (meta.body.lowerBound + (isFullBox ? 4 : 0))..<meta.body.upperBound
        try forEachAtom(reader, in: children, parent: meta) { ilst throws(ParseFailure) in
            guard ilst.type == "ilst" else { return true }
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

/// An item holds a `data` atom: a type code, a locale, then the value. Freeform items also hold
/// `mean` and `name`. Unknown items are skipped without reading their values.
private func read(_ item: Atom, _ reader: ByteReader, into items: inout ILSTItems)
    throws(ParseFailure)
{
    guard let kind = itemKinds[item.type] else { return }
    var data: Atom?
    var mean: String?
    var name: String?
    try forEachAtom(reader, in: item.body, parent: item) { child throws(ParseFailure) in
        switch child.type {
        case "data" where data == nil: data = child
        case "mean": mean = latin1(try reader.bytes(child.body).suffix(from: 4).array)
        case "name": name = latin1(try reader.bytes(child.body).suffix(from: 4).array)
        default: break
        }
        return true
    }
    guard let data else { return }
    guard data.body.count >= 8 else {
        throw .malformed(at: data.start, "MP4 '\(item.type)' data atom is too short")
    }
    let header = try reader.bytes(data.body.lowerBound..<data.body.lowerBound + 8)
    let type = try header.uint32BE(0) & 0xFF_FFFF
    let valueRange = data.body.lowerBound + 8..<data.body.upperBound
    let offset = valueRange.lowerBound
    if case .cover = kind {
        guard items.art == nil else { return }
        let head = try reader.bytes(valueRange.lowerBound..<min(valueRange.upperBound, offset + 8))
        guard let mime = artTypes[type] ?? (type == 0 ? sniffedMIMEType(head.array) : nil) else {
            throw .unsupported(at: data.start, "MP4 cover art with data type \(type)")
        }
        items.art = EmbeddedArt(
            offset: offset, byteCount: valueRange.count, mimeType: mime, unsynchronised: false)
        return
    }

    let value = try reader.bytes(valueRange)
    switch kind {
    case .text(let field):
        let text = try text(value, type, at: offset, &reader.warnings)
        items.tags.set(field, text, at: offset, warnings: &reader.warnings)
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
        guard mean == "com.apple.iTunes", name == "iTunSMPB" else { return }
        let text = try text(value, type, at: offset, &reader.warnings)
        items.gaplessLength = try gaplessLength(text, at: offset)
    case .cover:
        break
    }
}

private func text(
    _ value: Bytes, _ type: UInt32, at offset: Int, _ warnings: inout [MetadataWarning]
) throws(ParseFailure) -> String {
    switch type {
    case 1: TextEncoding.utf8.decode(value.array, at: offset, warnings: &warnings)
    case 2: TextEncoding.utf16BigEndian.decode(value.array, at: offset, warnings: &warnings)
    default: throw .malformed(at: offset, "MP4 text item with data type \(type)")
    }
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
