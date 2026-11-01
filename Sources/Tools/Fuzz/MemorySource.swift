import Metadata

/// An input in memory, read through the same `ByteReader` the parsers use on a file.
final class MemorySource: ByteSource {
    let bytes: [UInt8]

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var size: Int { bytes.count }

    func read(_ range: Range<Int>) throws(ParseFailure) -> [UInt8] { Array(bytes[range]) }
}
