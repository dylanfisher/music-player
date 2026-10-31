/// Serves byte ranges of one file. A range outside the last read costs a new read of at least
/// `minimumReadBytes`, so the fields of one header arrive together and a file whose tags fit in
/// the first read costs one round trip. Every read may be a slow trip to a NAS, so callers skip
/// art and audio by length instead of reading through them.
final class ByteReader {
    static let minimumReadBytes = 16 * 1024
    /// The most this holds in memory at once. Only tag text and unsynchronised ID3 tags come near
    /// it; art and audio are never read.
    static let maximumRangeBytes = 16 * 1024 * 1024

    let size: Int
    private(set) var bytesRead = 0
    private(set) var readCount = 0
    private let source: any ByteSource
    private var window: [UInt8] = []
    private var windowStart = 0

    init(_ source: any ByteSource) {
        self.source = source
        size = source.size
    }

    /// Bytes `range` of the file. Fails without reading when the range runs past the end, so a
    /// length from the file never sizes an allocation larger than the file.
    func bytes(_ range: Range<Int>) throws(ParseFailure) -> Bytes {
        guard range.lowerBound >= 0, range.upperBound <= size else {
            throw .malformed(
                at: range.lowerBound,
                "needs \(range.count) bytes, past the end of the file (\(size) bytes)")
        }
        guard range.count <= Self.maximumRangeBytes else {
            throw .unsupported(
                at: range.lowerBound,
                "a \(range.count)-byte block, more than the \(Self.maximumRangeBytes) this reads")
        }
        if range.lowerBound < windowStart || range.upperBound > windowStart + window.count {
            let end = min(size, max(range.upperBound, range.lowerBound + Self.minimumReadBytes))
            window = try source.read(range.lowerBound..<end)
            windowStart = range.lowerBound
            bytesRead += window.count
            readCount += 1
        }
        return Bytes(
            window, start: range.lowerBound - windowStart, count: range.count, base: windowStart)
    }
}
