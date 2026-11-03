/// Bytes from one place in a file. Every accessor takes an offset into these bytes and throws,
/// rather than trapping, when the field runs past the end, naming the field's place in the file.
package struct Bytes {
    package let count: Int
    private let storage: [UInt8]
    private let start: Int
    /// The file offset of `storage[0]`.
    private let base: Int
    /// Set when `storage` is an unsynchronised ID3 tag with its escapes removed.
    private let escapes: UnsyncEscapes?

    init(
        _ storage: [UInt8], start: Int = 0, count: Int? = nil, base: Int,
        escapes: UnsyncEscapes? = nil
    ) {
        self.storage = storage
        self.start = start
        self.count = count ?? storage.count - start
        self.base = base
        self.escapes = escapes
    }

    /// `storage` read from file offset `base`.
    package init(_ storage: [UInt8], base: Int) {
        self.init(storage, start: 0, count: nil, base: base)
    }

    /// Where byte `index` came from in the file.
    func fileOffset(_ index: Int) -> Int {
        base + (escapes?.rawIndex(start + index) ?? start + index)
    }

    package func slice(_ range: Range<Int>) throws(ParseFailure) -> Bytes {
        try check(range.lowerBound, range.count)
        return Bytes(
            storage, start: start + range.lowerBound, count: range.count, base: base,
            escapes: escapes)
    }

    /// From `offset` to the end.
    package func suffix(from offset: Int) throws(ParseFailure) -> Bytes {
        try check(offset, 0)
        return try slice(offset..<count)
    }

    package var array: [UInt8] { Array(storage[start..<start + count]) }

    package func uint8(_ offset: Int) throws(ParseFailure) -> UInt8 {
        try check(offset, 1)
        return storage[start + offset]
    }

    func uint16BE(_ offset: Int) throws(ParseFailure) -> UInt16 {
        UInt16(try bigEndian(offset, 2))
    }
    package func uint24BE(_ offset: Int) throws(ParseFailure) -> UInt32 {
        UInt32(try bigEndian(offset, 3))
    }
    package func uint32BE(_ offset: Int) throws(ParseFailure) -> UInt32 {
        UInt32(try bigEndian(offset, 4))
    }
    package func uint64BE(_ offset: Int) throws(ParseFailure) -> UInt64 { try bigEndian(offset, 8) }
    func uint16LE(_ offset: Int) throws(ParseFailure) -> UInt16 {
        UInt16(try littleEndian(offset, 2))
    }
    package func uint32LE(_ offset: Int) throws(ParseFailure) -> UInt32 {
        UInt32(try littleEndian(offset, 4))
    }
    func uint64LE(_ offset: Int) throws(ParseFailure) -> UInt64 { try littleEndian(offset, 8) }

    /// ID3v2's 28-bit integer, seven bits per byte. Nil when a byte has its top bit set.
    package func syncsafe(_ offset: Int) throws(ParseFailure) -> Int? {
        try check(offset, 4)
        var value = 0
        for byte in storage[start + offset..<start + offset + 4] {
            guard byte & 0x80 == 0 else { return nil }
            value = value << 7 | Int(byte)
        }
        return value
    }

    /// Four bytes as Latin-1, the way MP4 atom types and RIFF chunk IDs are written.
    func fourCC(_ offset: Int) throws(ParseFailure) -> String {
        try check(offset, 4)
        return latin1(storage[start + offset..<start + offset + 4])
    }

    /// Whether the bytes at `offset` are `ascii`; false when they'd run past the end.
    package func matches(_ ascii: String, at offset: Int) -> Bool {
        let expected = Array(ascii.utf8)
        guard offset >= 0, offset + expected.count <= count else { return false }
        return storage[start + offset..<start + offset + expected.count].elementsEqual(expected)
    }

    /// The first index at or after `offset` where `pattern` starts, stepping by its length so a
    /// UTF-16 terminator is only found on a character boundary.
    func firstIndex(of pattern: [UInt8], from offset: Int) -> Int? {
        var index = offset
        while index + pattern.count <= count {
            if storage[start + index..<start + index + pattern.count].elementsEqual(pattern) {
                return index
            }
            index += pattern.count
        }
        return nil
    }

    private func check(_ offset: Int, _ length: Int) throws(ParseFailure) {
        guard offset >= 0, length >= 0, offset <= count - length else {
            throw .malformed(
                at: fileOffset(min(max(offset, 0), count)),
                "a \(length)-byte field at \(offset) runs past the end of its \(count)-byte block")
        }
    }

    private func bigEndian(_ offset: Int, _ length: Int) throws(ParseFailure) -> UInt64 {
        try check(offset, length)
        return storage[start + offset..<start + offset + length].reduce(0) { $0 << 8 | UInt64($1) }
    }

    private func littleEndian(_ offset: Int, _ length: Int) throws(ParseFailure) -> UInt64 {
        try check(offset, length)
        return storage[start + offset..<start + offset + length].reversed()
            .reduce(0) { $0 << 8 | UInt64($1) }
    }
}

/// Bytes as Latin-1, which maps each byte to the code point of the same value.
package func latin1(_ bytes: some Collection<UInt8>) -> String {
    // Written as UTF-8 in one pass: appending scalars one at a time cost a sixth of a full parse,
    // most of it in the MP4 atom types.
    String(unsafeUninitializedCapacity: bytes.count * 2) { utf8 in
        var count = 0
        for byte in bytes {
            if byte < 0x80 {
                utf8[count] = byte
                count += 1
            } else {
                utf8[count] = 0xC0 | byte >> 6
                utf8[count + 1] = 0x80 | byte & 0x3F
                count += 2
            }
        }
        return count
    }
}
