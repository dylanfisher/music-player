import Foundation
import Metadata

/// An MP4 seed split so a new `udta/meta/ilst` can go into `moov`. Growing `moov` moves `mdat`,
/// so the chunk offsets in `stco` are rewritten for each file.
struct MP4Seed: Sendable {
    private let ftyp: Data
    /// `moov`'s children except `udta`.
    private let moovChildren: Data
    /// Where each `stco` entry sits in `moovChildren`.
    private let chunkOffsetPositions: [Int]
    /// The seed's `meta/hdlr`, which marks the metadata as iTunes-style.
    private let metadataHandler: Data
    /// The seed's own `ilst` items, kept because AAC's `iTunSMPB` holds its priming and length.
    private let seedItems: Data
    private let mdat: Data
    private let seedMdatOffset: Int

    init(_ data: Data) throws {
        var ftyp: Data?
        var moov: Range<Int>?
        var mdat: Range<Int>?
        for atom in try atoms(in: data, 0..<data.count) {
            switch atom.type {
            case "ftyp": ftyp = data[atom.range]
            case "moov": moov = atom.body
            case "mdat": mdat = atom.range
            default: continue  // `free` padding, which the rebuilt file doesn't need
            }
        }
        guard let ftyp, let moov, let mdat else {
            throw FixtureError.unexpectedSeed("MP4 without ftyp, moov and mdat")
        }

        var children = Data()
        var positions: [Int] = []
        var handler: Data?
        var items = Data()
        for child in try atoms(in: data, moov) {
            if child.type == "udta" {
                for meta in try atoms(in: data, child.body) where meta.type == "meta" {
                    // `meta` is a full box: four bytes of version and flags before its children.
                    let metaChildren = (meta.body.lowerBound + 4)..<meta.body.upperBound
                    for entry in try atoms(in: data, metaChildren) {
                        if entry.type == "hdlr" { handler = data[entry.range] }
                        if entry.type == "ilst" { items = data[entry.body] }
                    }
                }
                continue
            }
            let base = children.count - child.range.lowerBound
            positions += try chunkOffsetEntries(in: data, child).map { $0 + base }
            children.append(data[child.range])
        }
        guard let handler else { throw FixtureError.unexpectedSeed("MP4 without meta/hdlr") }

        self.ftyp = Data(ftyp)
        moovChildren = children
        chunkOffsetPositions = positions
        metadataHandler = Data(handler)
        seedItems = Data(items)
        self.mdat = Data(data[mdat])
        seedMdatOffset = mdat.lowerBound
    }

    /// The file with `items` appended to the seed's `ilst`.
    func file(items: Data) -> Data {
        var meta = Data(count: 4)
        meta.append(metadataHandler)
        meta.append(atom("ilst", seedItems + items))
        var children = moovChildren
        children.append(atom("udta", atom("meta", meta)))
        let moovSize = 8 + children.count
        let shift = ftyp.count + moovSize - seedMdatOffset
        for position in chunkOffsetPositions {
            let offset = Int(children.readBigEndianUInt32(at: position)) + shift
            children.replaceBigEndian(UInt32(offset), at: position)
        }
        return ftyp + atom("moov", children) + mdat
    }
}

struct Atom {
    var type: String
    var range: Range<Int>
    var body: Range<Int>
}

/// The atoms that tile `range`.
private func atoms(in data: Data, _ range: Range<Int>) throws -> [Atom] {
    var found: [Atom] = []
    var offset = range.lowerBound
    while offset < range.upperBound {
        let size = Int(data.readBigEndianUInt32(at: offset))
        guard size >= 8, offset + size <= range.upperBound else {
            throw FixtureError.unexpectedSeed("MP4 atom at \(offset) has size \(size)")
        }
        let type = String(data: data[offset + 4..<offset + 8], encoding: .isoLatin1)!
        found.append(
            Atom(type: type, range: offset..<offset + size, body: offset + 8..<offset + size))
        offset += size
    }
    return found
}

/// File positions of every `stco` entry under `atom`, a `moov` child.
private func chunkOffsetEntries(in data: Data, _ atom: Atom) throws -> [Int] {
    switch atom.type {
    case "trak", "mdia", "minf", "stbl":
        return try atoms(in: data, atom.body).flatMap { try chunkOffsetEntries(in: data, $0) }
    case "stco":
        // Version and flags, then the entry count, then 32-bit offsets.
        let count = Int(data.readBigEndianUInt32(at: atom.body.lowerBound + 4))
        return (0..<count).map { atom.body.lowerBound + 8 + 4 * $0 }
    case "co64":
        throw FixtureError.unexpectedSeed("64-bit chunk offsets in a tiny file")
    default:
        return []
    }
}

/// Atom types are four Latin-1 bytes; the iTunes text items start with "©", byte 0xA9.
func atom(_ type: String, _ body: Data) -> Data {
    let typeBytes = type.data(using: .isoLatin1)!
    precondition(typeBytes.count == 4, "atom type \(type) isn't four bytes")
    var atom = Data()
    atom.appendBigEndian(UInt32(8 + body.count))
    atom.append(typeBytes)
    atom.append(body)
    return atom
}

/// iTunes `ilst` items for `tags`. `genreAsIndex` writes the genre as an ID3v1 index in `gnre`,
/// as older iTunes did, when it has one.
func mp4Items(_ tags: FixtureTags, art: Artwork?, genreAsIndex: Bool) -> Data {
    var items = Data()
    func text(_ type: String, _ value: String?) {
        if let value { items.append(atom(type, dataAtom(1, Data(value.utf8)))) }
    }
    text("\u{A9}nam", tags.title)
    text("\u{A9}ART", tags.artist)
    text("\u{A9}alb", tags.album)
    text("aART", tags.albumArtist)
    if let genre = tags.genre {
        if genreAsIndex, let index = id3v1GenreIndex(genre) {
            var body = Data()
            body.appendBigEndian(UInt16(index + 1))
            items.append(atom("gnre", dataAtom(0, body)))
        } else {
            text("\u{A9}gen", genre)
        }
    }
    text("\u{A9}day", tags.date)
    if let track = tags.trackNumber {
        var body = Data(count: 2)
        body.appendBigEndian(UInt16(track))
        body.appendBigEndian(UInt16(tags.trackTotal ?? 0))
        body.append(Data(count: 2))
        items.append(atom("trkn", dataAtom(0, body)))
    }
    if let disc = tags.discNumber {
        var body = Data(count: 2)
        body.appendBigEndian(UInt16(disc))
        body.appendBigEndian(UInt16(tags.discTotal ?? 0))
        items.append(atom("disk", dataAtom(0, body)))
    }
    if tags.compilation { items.append(atom("cpil", dataAtom(21, Data([1])))) }
    text("\u{A9}cmt", tags.comment)
    if let art {
        items.append(atom("covr", dataAtom(art.mimeType == pngMIMEType ? 14 : 13, art.data)))
    }
    return items
}

/// A `data` atom: a type code (1 UTF-8, 0 implicit, 13 JPEG, 14 PNG, 21 integer), a zero
/// locale, then the value.
private func dataAtom(_ type: UInt32, _ value: Data) -> Data {
    var body = Data()
    body.appendBigEndian(type)
    body.appendBigEndian(UInt32(0))
    body.append(value)
    return atom("data", body)
}
