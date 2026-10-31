import Foundation

/// Appends integers in the byte orders the tag formats use.
extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    /// The low three bytes, big-endian, as in FLAC block headers and ID3v2.2 frame sizes.
    mutating func appendUInt24(_ value: Int) {
        precondition(value < 1 << 24, "\(value) doesn't fit in 24 bits")
        append(contentsOf: [16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) })
    }

    /// ID3v2's 28-bit integer: four bytes of seven bits each, so it never contains a sync byte.
    mutating func appendSyncsafe(_ value: Int) {
        precondition(value < 1 << 28, "\(value) doesn't fit in 28 bits")
        append(contentsOf: [21, 14, 7, 0].map { UInt8(truncatingIfNeeded: value >> $0) & 0x7F })
    }

    mutating func append(ascii: String) {
        precondition(ascii.allSatisfy(\.isASCII), "\"\(ascii)\" isn't ASCII")
        append(contentsOf: Array(ascii.utf8))
    }

    func readBigEndianUInt32(at offset: Int) -> UInt32 {
        self[startIndex + offset..<startIndex + offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    func readLittleEndianUInt32(at offset: Int) -> UInt32 {
        self[startIndex + offset..<startIndex + offset + 4].reversed()
            .reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func replaceBigEndian(_ value: UInt32, at offset: Int) {
        var bytes = Data()
        bytes.appendBigEndian(value)
        replaceSubrange(startIndex + offset..<startIndex + offset + 4, with: bytes)
    }

    /// Where `ascii` first appears, counted from the start.
    func offset(of ascii: String) -> Int? {
        range(of: Data(ascii.utf8)).map { $0.lowerBound - startIndex }
    }
}
