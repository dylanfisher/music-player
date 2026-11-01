import Metadata

/// An MP4 atom held in memory. The writer opens only the containers on the way to `ilst` and to
/// the chunk offset tables; every other atom is kept as its bytes.
struct MP4Box {
    var type: String
    /// A 16-byte header with a 64-bit size, as read.
    var largeSize = false
    /// Bytes between the header and the children: `meta`'s version and flags.
    var prefix: [UInt8] = []
    /// Nil for an atom kept as its bytes.
    var children: [MP4Box]?
    /// A kept atom's body.
    var body: [UInt8] = []
    /// A container's bytes after its last child, such as QuickTime's 32-bit zero terminator.
    var trailer: [UInt8] = []
    /// Where the atom was in the file; nil for one the writer made.
    var original: Range<Int>?

    /// The containers opened under `moov`, and under them `ilst`'s items stay whole.
    static let opened: Set<String> = [
        MP4Type.moov, MP4Type.trak, MP4Type.mdia, MP4Type.minf, MP4Type.stbl, MP4Type.udta,
        MP4Type.meta, MP4Type.ilst,
    ]
    static let paddingTypes: Set<String> = [MP4Type.free, "skip"]
    static let chunkOffsetTypes: Set<String> = [MP4Type.stco, MP4Type.co64]

    init(type: String, body: [UInt8]) {
        self.type = type
        self.body = body
    }

    init(type: String, prefix: [UInt8] = [], children: [MP4Box]) {
        self.type = type
        self.prefix = prefix
        self.children = children
    }

    /// Reads the atom `atom` from `reader`, opening it if it's one of `opened`.
    init(_ atom: Atom, _ reader: ByteReader) throws(ParseFailure) {
        type = atom.type
        original = atom.start..<atom.body.upperBound
        largeSize = atom.body.lowerBound - atom.start == 16
        guard Self.opened.contains(type) else {
            body = try reader.bytes(atom.body).array
            return
        }
        var start = atom.body.lowerBound
        if type == MP4Type.meta {
            // iTunes writes `meta` as a full box, with version and flags before its children.
            let first = try reader.bytes(start..<min(atom.body.upperBound, start + 4))
            if first.count == 4, try first.uint32BE(0) == 0 {
                prefix = first.array
                start += 4
            }
        }
        var children: [MP4Box] = []
        var end = start
        try forEachAtom(reader, in: start..<atom.body.upperBound, parent: atom) {
            child throws(ParseFailure) in
            children.append(try MP4Box(child, reader))
            end = child.body.upperBound
            return true
        }
        self.children = children
        trailer = try reader.bytes(end..<atom.body.upperBound).array
    }

    var byteCount: Int {
        let content = contentByteCount
        return content + (largeSize || content + 8 > Int(UInt32.max) ? 16 : 8)
    }

    private var contentByteCount: Int {
        guard let children else { return body.count }
        return prefix.count + children.reduce(0) { $0 + $1.byteCount } + trailer.count
    }

    func serialized() -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(byteCount)
        append(to: &bytes)
        return bytes
    }

    private func append(to bytes: inout [UInt8]) {
        let size = byteCount
        if size - contentByteCount == 16 {
            bytes += bigEndianBytes(1, 4) + Array(type.unicodeScalars.map { UInt8($0.value) })
            bytes += bigEndianBytes(size, 8)
        } else {
            bytes += bigEndianBytes(size, 4) + Array(type.unicodeScalars.map { UInt8($0.value) })
        }
        guard let children else {
            bytes += body
            return
        }
        bytes += prefix
        for child in children { child.append(to: &bytes) }
        bytes += trailer
    }

    func child(_ type: String) -> MP4Box? { children?.first { $0.type == type } }

    /// The child path `types` below this atom, as indices, or nil when one is missing.
    func indexPath(_ types: [String]) -> [Int]? {
        guard let first = types.first else { return [] }
        guard let index = children?.firstIndex(where: { $0.type == first }),
            let rest = children![index].indexPath(Array(types.dropFirst()))
        else { return nil }
        return [index] + rest
    }

    subscript(path: [Int]) -> MP4Box {
        get { path.isEmpty ? self : children![path[0]][Array(path.dropFirst())] }
        set {
            if path.isEmpty {
                self = newValue
            } else {
                children![path[0]][Array(path.dropFirst())] = newValue
            }
        }
    }

    /// Every chunk offset table under this atom, as paths of indices.
    func chunkOffsetTables(at path: [Int] = []) -> [[Int]] {
        guard let children else { return Self.chunkOffsetTypes.contains(type) ? [path] : [] }
        return children.indices.flatMap { children[$0].chunkOffsetTables(at: path + [$0]) }
    }

    /// The entries of an `stco` or `co64`: version and flags, a count, then 32- or 64-bit
    /// offsets.
    func chunkOffsets() throws(ParseFailure) -> [Int] {
        let table = Bytes(body, base: 0)
        let width = type == MP4Type.co64 ? 8 : 4
        let count = Int(try table.uint32BE(4))
        guard count <= (body.count - 8) / width else {
            throw .malformed(
                at: original?.lowerBound ?? 0, "MP4 \(type) count \(count) is too large")
        }
        var offsets: [Int] = []
        offsets.reserveCapacity(count)
        for index in 0..<count {
            let at = 8 + index * width
            offsets.append(
                width == 8 ? Int(try table.uint64BE(at)) : Int(try table.uint32BE(at)))
        }
        return offsets
    }

    /// Adds `delta` to every entry at or after `from`. Throws when an `stco` entry would no
    /// longer fit in 32 bits.
    mutating func shiftChunkOffsets(by delta: Int, from: Int) throws(ParseFailure) {
        let width = type == MP4Type.co64 ? 8 : 4
        let offsets = try chunkOffsets()
        for (index, offset) in offsets.enumerated() where offset >= from {
            let shifted = offset + delta
            guard shifted >= 0, width == 8 || shifted <= Int(UInt32.max) else {
                throw .unsupported(
                    at: original?.lowerBound, "an MP4 chunk offset past 4 GB in a 32-bit stco")
            }
            body.replaceSubrange(
                8 + index * width..<8 + (index + 1) * width, with: bigEndianBytes(shifted, width))
        }
    }
}

/// The type of an `ilst` item and, for a `----` item, its `mean` and `name`.
func mp4ItemKey(_ item: MP4Box) -> String {
    guard item.type == MP4ItemType.freeform else { return item.type }
    var parts: [String] = []
    var cursor = 0
    while cursor + 8 <= item.body.count {
        let size = Int(bigEndianValue(item.body[cursor..<cursor + 4]))
        let type = String(decoding: item.body[cursor + 4..<cursor + 8], as: Unicode.ASCII.self)
        guard size >= 8, cursor + size <= item.body.count else { break }
        if type == MP4Type.mean || type == MP4Type.name, size >= 12 {
            parts.append(latin1(item.body[cursor + 12..<cursor + size]))
        }
        cursor += size
    }
    return ([item.type] + parts).joined(separator: ":")
}

func bigEndianValue(_ bytes: some Collection<UInt8>) -> UInt64 {
    bytes.reduce(0) { $0 << 8 | UInt64($1) }
}
