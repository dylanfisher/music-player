import Metadata

/// An MP4 file's top-level atoms, with `moov` in memory and `mdat` left in the file.
struct MP4File {
    /// `meta/hdlr` as iTunes writes it: the "mdir" handler from "appl", with an empty name.
    static let metadataHandler: [UInt8] =
        [0, 0, 0, 0, 0, 0, 0, 0] + Array("mdirappl".utf8) + [UInt8](repeating: 0, count: 9)
    static let ilstPath = [MP4Type.udta, MP4Type.meta, MP4Type.ilst]

    var size: Int
    /// The top-level atoms in file order; only `moov` is read.
    var top: [(atom: Atom, box: MP4Box?)]
    var moovIndex: Int

    init(_ reader: ByteReader) throws(ParseFailure) {
        size = reader.size
        var top: [(atom: Atom, box: MP4Box?)] = []
        var moovIndex: Int?
        try forEachAtom(reader, in: 0..<reader.size, parent: nil) { atom throws(ParseFailure) in
            switch atom.type {
            case MP4Type.moov:
                guard moovIndex == nil else {
                    throw .unsupported(at: atom.start, "an MP4 file with two moov atoms")
                }
                moovIndex = top.count
                top.append((atom, try MP4Box(atom, reader)))
            case "moof":
                throw .unsupported(at: atom.start, "writing tags in a fragmented MP4 file")
            default:
                top.append((atom, nil))
            }
            return true
        }
        guard let moovIndex else { throw .malformed(at: 0, mp4WithoutMoov) }
        self.top = top
        self.moovIndex = moovIndex
    }

    var moov: MP4Box { top[moovIndex].box! }
    var moovAtom: Atom { top[moovIndex].atom }
    var mdats: [Atom] { top.map(\.atom).filter { $0.type == MP4Type.mdat } }
    var payload: [Range<Int>] { mdats.map(\.body) }
    /// Whether audio follows `moov`, so a `moov` that changes size moves it.
    var audioAfterMoov: Bool { mdats.contains { $0.start > moovAtom.start } }

    // MARK: Editing

    /// The new file as segments: `moov` rebuilt, the rest of the file kept. Grows into `free`
    /// first; when that runs out and audio follows, every chunk offset moves with it.
    func rewrite(_ groups: [TagGroup], from tags: TrackTags, art: ArtChange?) throws(ParseFailure)
        -> [Segment]
    {
        var moov = self.moov
        let oldSize = moov.byteCount
        let path = try ensureItemList(&moov)
        var ilst = moov[path]
        if let art { applyArt(art, to: &ilst) }
        for group in groups {
            let isReplaced = { (item: MP4Box) in item.group?.isReplaced(by: group) == true }
            let new = items(group, tags)
            let first = ilst.children!.firstIndex(where: isReplaced)
            ilst.children!.removeAll(where: isReplaced)
            ilst.children!.insert(
                contentsOf: new, at: min(first ?? ilst.children!.count, ilst.children!.count))
        }
        moov[path] = ilst

        // A top-level `free` right after `moov` can take the change too.
        var replacedEnd = moovAtom.body.upperBound
        var trailingFree: Int?
        if moovIndex + 1 < top.count, MP4Box.paddingTypes.contains(top[moovIndex + 1].atom.type) {
            trailingFree = top[moovIndex + 1].atom.body.upperBound - moovAtom.body.upperBound
        }
        var delta = moov.byteCount - oldSize
        if delta != 0, absorb(delta, into: &moov, ilstPath: path) {
            delta = 0
        }
        var tail: [UInt8] = []
        if delta != 0, let free = trailingFree, free - delta >= 8 || free == delta {
            replacedEnd += free
            if free != delta {
                let type = top[moovIndex + 1].atom.type
                tail = MP4Box(type: type, body: zeros(free - delta - 8)).serialized()
            }
            delta = 0
        }
        if delta <= -8 {
            // Shrunk with nowhere to give the bytes: a new `free` keeps the audio in place.
            addPadding(-delta, to: &moov, ilstPath: path)
            delta = 0
        }
        if delta != 0 {
            // The audio moves anyway, so leave room for the next edits.
            addPadding(
                rewritePaddingBytes(tagBytes: moov[path].byteCount), to: &moov, ilstPath: path)
            delta = moov.byteCount - oldSize
            if audioAfterMoov {
                for table in moov.chunkOffsetTables() {
                    try moov[table].shiftChunkOffsets(by: delta, from: moovAtom.body.upperBound)
                }
            }
        }
        return [
            .original(0..<moovAtom.start), .bytes(moov.serialized() + tail),
            .original(replacedEnd..<size),
        ]
    }

    /// The path to `udta/meta/ilst` under `moov`, made with an iTunes `hdlr` when missing.
    private func ensureItemList(_ moov: inout MP4Box) throws(ParseFailure) -> [Int] {
        if let path = moov.indexPath(Self.ilstPath) { return path }
        if moov.child(MP4Type.udta) == nil {
            moov.children!.append(MP4Box(type: MP4Type.udta, children: []))
        }
        var udtaPath = moov.indexPath([MP4Type.udta])!
        if moov[udtaPath].child(MP4Type.meta) == nil {
            moov[udtaPath].children!.append(
                MP4Box(
                    type: MP4Type.meta, prefix: [0, 0, 0, 0],
                    children: [MP4Box(type: MP4Type.hdlr, body: Self.metadataHandler)]))
        }
        udtaPath += [moov[udtaPath].children!.firstIndex { $0.type == MP4Type.meta }!]
        moov[udtaPath].children!.append(MP4Box(type: MP4Type.ilst, children: []))
        return udtaPath + [moov[udtaPath].children!.count - 1]
    }

    /// Takes `delta` bytes from (or gives them to) the first `free` beside `ilst`, `meta` or
    /// `udta`. A `free` keeps at least its header, or goes when it's exactly used up.
    private func absorb(_ delta: Int, into moov: inout MP4Box, ilstPath: [Int]) -> Bool {
        for depth in stride(from: ilstPath.count, to: 0, by: -1) {
            let parent = Array(ilstPath.prefix(depth - 1))
            guard
                let index = moov[parent].children!.firstIndex(where: {
                    MP4Box.paddingTypes.contains($0.type) && $0.children == nil
                })
            else { continue }
            let free = moov[parent].children![index]
            let size = free.byteCount
            if size == delta {
                moov[parent].children!.remove(at: index)
                return true
            }
            if free.body.count >= delta {
                moov[parent].children![index].body = zeros(free.body.count - delta)
                return true
            }
        }
        return false
    }

    private func addPadding(_ bytes: Int, to moov: inout MP4Box, ilstPath: [Int]) {
        let meta = Array(ilstPath.dropLast())
        if let index = moov[meta].children!.firstIndex(where: {
            MP4Box.paddingTypes.contains($0.type) && $0.children == nil
        }) {
            moov[meta].children![index].body += zeros(bytes)
        } else {
            moov[meta].children!.insert(
                MP4Box(type: MP4Type.free, body: zeros(bytes - 8)), at: ilstPath.last! + 1)
        }
    }

    /// The items for `group` with its values in `tags`; none to leave none.
    private func items(_ group: TagGroup, _ tags: TrackTags) -> [MP4Box] {
        switch group {
        case .track, .disc:
            let (number, total) = group.numbers(in: tags)
            guard number != nil || total != nil else { return [] }
            let value =
                [0, 0] + bigEndianBytes(number ?? 0, 2) + bigEndianBytes(total ?? 0, 2)
                + (group == .track ? [0, 0] : [])
            let type = group == .track ? MP4ItemType.track : MP4ItemType.disc
            return [MP4Box(type: type, body: dataAtom(0, value))]
        case .compilation:
            guard tags.compilation else { return [] }
            return [MP4Box(type: MP4ItemType.compilation, body: dataAtom(signedIntegerType, [1]))]
        case .movement:
            // iTunes keeps the movement and its count in items of their own.
            let (number, total) = group.numbers(in: tags)
            return zip(group.readerFields, [number, total]).compactMap { field, value in
                value.map { integerItem(field, $0) }
            }
        case .bpm:
            return tags.bpm.map { [integerItem(.bpm, $0)] } ?? []
        case .text(let field):
            guard let text = group.text(in: tags) else { return [] }
            switch writtenKey(field) {
            case .item(let type):
                return [MP4Box(type: type, body: dataAtom(utf8TextType, Array(text.utf8)))]
            case .freeform(let name): return [freeformItem(name, text)]
            }
        case .custom(let name):
            return group.text(in: tags).map { [freeformItem(name, $0)] } ?? []
        }
    }

    /// An iTunes freeform item, `----:com.apple.iTunes:<name>`, holding `text`.
    private func freeformItem(_ name: String, _ text: String) -> MP4Box {
        let body =
            fullAtom(MP4Type.mean, Array(iTunesMean.utf8))
            + fullAtom(MP4Type.name, Array(name.utf8))
            + dataAtom(utf8TextType, Array(text.utf8))
        return MP4Box(type: MP4ItemType.freeform, body: body)
    }

    /// A 16-bit integer item, as iTunes writes `tmpo`, `©mvi` and `©mvc`.
    private func integerItem(_ field: TagField, _ value: Int) -> MP4Box {
        guard case .item(let type) = writtenKey(field) else {
            preconditionFailure("\(field) is an integer item")
        }
        return MP4Box(type: type, body: dataAtom(signedIntegerType, bigEndianBytes(value, 2)))
    }

    private func writtenKey(_ field: TagField) -> MP4Key {
        guard let key = mp4WrittenKey(for: field) else {
            preconditionFailure("\(field) has no MP4 item")
        }
        return key
    }

    /// Replaces the first `data` atom of `covr`, which is the one the reader shows, or removes
    /// `covr` whole.
    private func applyArt(_ art: ArtChange, to ilst: inout MP4Box) {
        let index = ilst.children!.firstIndex { $0.type == mp4CoverItemType }
        switch art {
        case .remove:
            ilst.children!.removeAll { $0.type == mp4CoverItemType }
        case .replace(let image, let mimeType):
            let data = dataAtom(mimeType == pngMIMEType ? 14 : 13, Array(image))
            guard let index else {
                ilst.children!.append(MP4Box(type: mp4CoverItemType, body: data))
                return
            }
            var body = ilst.children![index].body
            var cursor = 0
            while cursor + 8 <= body.count {
                let size = Int(bigEndianValue(body[cursor..<cursor + 4]))
                guard size >= 8, cursor + size <= body.count else { break }
                if body[cursor + 4..<cursor + 8].elementsEqual(MP4Type.data.utf8) {
                    body.replaceSubrange(cursor..<cursor + size, with: data)
                    ilst.children![index].body = body
                    return
                }
                cursor += size
            }
            ilst.children![index].body = data
        }
    }

    // MARK: Layout

    func layout() throws(ParseFailure) -> TagLayout {
        var blocks: [TagBlock] = []
        var notes: [String] = []
        for (atom, box) in top {
            let range = atom.start..<atom.body.upperBound
            if let box {
                blocks += boxBlocks(box, path: MP4Type.moov, at: atom.start)
            } else if atom.type == MP4Type.mdat {
                blocks.append(TagBlock(MP4Type.mdat, range, .audio))
            } else if MP4Box.paddingTypes.contains(atom.type) {
                blocks.append(TagBlock(atom.type, range, .padding))
            } else {
                blocks.append(TagBlock(atom.type, range, .other))
            }
        }
        notes.append(audioAfterMoov ? "moov before mdat" : "moov after mdat")
        // Its tags grow in place, past the end of the file (ADR 0108).
        if moovIndex == top.count - 1 { notes.append("moov last") }
        let tables = Set(moov.chunkOffsetTables().map { moov[$0].type })
        notes.append("chunk offsets: \(tables.sorted().joined(separator: ", "))")
        if moov.indexPath(Self.ilstPath) == nil { notes.append("no udta/meta/ilst") }
        if let meta = moov.indexPath([MP4Type.udta, MP4Type.meta]), moov[meta].prefix.isEmpty {
            notes.append("meta isn't a full box")
        }
        if mdats.count != 1 { notes.append("\(mdats.count) mdat atoms") }
        return TagLayout(container: .mp4, blocks: blocks, payload: payload, notes: notes)
    }

    private func boxBlocks(_ box: MP4Box, path: String, at start: Int) -> [TagBlock] {
        let range = start..<start + box.byteCount
        guard let children = box.children else {
            if MP4Box.paddingTypes.contains(box.type) { return [TagBlock(path, range, .padding)] }
            if MP4Box.chunkOffsetTypes.contains(box.type) {
                return [TagBlock(path, range, .chunkOffsets)]
            }
            if path.hasPrefix("moov/udta/meta/ilst/") {
                if box.type == mp4CoverItemType { return [TagBlock(path, range, .art)] }
                return [
                    TagBlock(
                        String(path.dropLast(box.type.count)) + mp4ItemKey(box), range, .field,
                        group: box.group)
                ]
            }
            return [TagBlock(path, range, .other)]
        }
        let header =
            box.byteCount - box.children!.reduce(0) { $0 + $1.byteCount }
            - box.trailer.count
        var blocks = [TagBlock(path, start..<start + header, .header)]
        var cursor = start + header
        for child in children {
            blocks += boxBlocks(child, path: "\(path)/\(child.type)", at: cursor)
            cursor += child.byteCount
        }
        if !box.trailer.isEmpty {
            blocks.append(TagBlock("\(path)/trailer", cursor..<range.upperBound, .other))
        }
        return blocks
    }
}

/// `data` atom type codes: UTF-8 text, and a big-endian signed integer.
private let utf8TextType: UInt32 = 1
private let signedIntegerType: UInt32 = 21

/// A `data` atom: a type code, a zero locale, then the value.
private func dataAtom(_ type: UInt32, _ value: [UInt8]) -> [UInt8] {
    MP4Box(type: MP4Type.data, body: bigEndianBytes(Int(type), 4) + [0, 0, 0, 0] + value)
        .serialized()
}

/// A freeform item's `mean` or `name`: a zero version and flags, then the text.
private func fullAtom(_ type: String, _ value: [UInt8]) -> [UInt8] {
    MP4Box(type: type, body: [0, 0, 0, 0] + value).serialized()
}

func zeros(_ count: Int) -> [UInt8] { [UInt8](repeating: 0, count: max(0, count)) }
