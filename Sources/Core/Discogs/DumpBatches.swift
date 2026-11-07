import Foundation

/// A dump's inflated bytes cut into batches of whole records, each wrapped in the dump's root
/// element so `XMLParser` reads it as a document of its own (ADR 0130). `XMLParser` keeps what
/// it autoreleases until its parse returns, so one parse over a whole dump would hold a string
/// for every element it read; a batch parsed in an autorelease pool of its own gives them all
/// back. The dumps write each record on a line of its own, so a record ends where its closing
/// tag ends a line; text can't hold a tag, as XML escapes its `<`. A dump laid out otherwise
/// fails to parse rather than being read wrong.
struct DumpBatches {
    /// About how much a batch holds: the records that end in it, past this many bytes.
    static let batchBytes = 4 << 20
    /// The longest record read; a dump with a longer one isn't laid out a record a line.
    static let largestRecordBytes = 64 << 20

    private let stream: GzipStream
    private let batchBytes: Int
    private let kind: DumpKind
    private let file: String
    private let rootStart: [UInt8]
    private let rootEnd: [UInt8]
    /// `</release>` and a line break: where a record ends.
    private let recordEnd: [UInt8]
    private var buffer: [UInt8] = []
    /// What one read inflates into, before it joins the buffer.
    private let block = Block()
    /// Whether the root's start tag has been passed.
    private var started = false
    /// The line of the file the buffer starts on.
    private var line = 1

    /// `batchBytes` is for tests, which cut their small dumps into many batches.
    init(_ stream: GzipStream, kind: DumpKind, file: String, batchBytes: Int = batchBytes) {
        self.stream = stream
        self.batchBytes = batchBytes
        self.kind = kind
        self.file = file
        rootStart = Array("<\(kind.rawValue)>".utf8)
        rootEnd = Array("</\(kind.rawValue)>".utf8)
        recordEnd = Array("</\(DumpElement(record: kind).rawValue)>\n".utf8)
        buffer.reserveCapacity(Self.batchBytes + GzipStream.readBytes)
    }

    /// The next batch, inside the root element, with the line of the file its first record is
    /// on; nil once the root has ended. Throws when the stream fails, or the bytes aren't a
    /// dump of whole records.
    mutating func next() throws -> (document: Data, firstLine: Int)? {
        while true {
            if !started, let end = range(of: rootStart, in: buffer[...])?.upperBound {
                guard isBlank(buffer[..<end].dropLast(rootStart.count)) else {
                    throw malformed("text before <\(kind.rawValue)>")
                }
                consume(end)
                started = true
            }
            let read = try fill()
            if started, buffer.count >= batchBytes || read == 0,
                let end = lastRecordEnd()
            {
                let batch = Data(rootStart) + Data(buffer[..<end]) + Data(rootEnd)
                let firstLine = line
                consume(end)
                return (batch, firstLine)
            }
            if read == 0 { return try finish() }
            if buffer.count > Self.largestRecordBytes {
                throw malformed(
                    "a record over \(Self.largestRecordBytes >> 20) MB, or no line breaks")
            }
        }
    }

    /// At the end of the stream, with no whole record left: what's left must be the root's
    /// end tag.
    private mutating func finish() throws -> (document: Data, firstLine: Int)? {
        guard started else { throw malformed("no <\(kind.rawValue)>") }
        guard let end = range(of: rootEnd, in: buffer[...]),
            isBlank(buffer[..<end.lowerBound]), isBlank(buffer[end.upperBound...])
        else { throw malformed("the file ends inside a record") }
        buffer.removeAll()
        return nil
    }

    /// Reads another block of inflated bytes onto the buffer: how many, 0 at the end.
    private mutating func fill() throws -> Int {
        let count = stream.read(block.baseAddress!, maxLength: block.count)
        guard count >= 0 else {
            throw stream.failure ?? CatalogImportError.unreadable(file, "the stream failed")
        }
        buffer.append(contentsOf: block.prefix(count))
        return count
    }

    /// Drops the buffer's first `count` bytes, counting the lines they end.
    private mutating func consume(_ count: Int) {
        line += buffer.withUnsafeBufferPointer { bytes in
            var lines = 0
            for index in 0..<count where bytes[index] == UInt8(ascii: "\n") { lines += 1 }
            return lines
        }
        buffer.removeFirst(count)
    }

    /// The end of the buffer's last whole record, if it has one.
    private func lastRecordEnd() -> Int? {
        var index = buffer.count
        while let newline = buffer[..<index].lastIndex(of: UInt8(ascii: "\n")) {
            let start = newline + 1 - recordEnd.count
            if start >= 0, buffer[start...newline].elementsEqual(recordEnd) { return newline + 1 }
            index = newline
        }
        return nil
    }

    private func malformed(_ reason: String) -> CatalogImportError {
        .malformed(file, line: line, reason)
    }
}

/// A buffer of `GzipStream.readBytes`, freed with the batches that read into it.
private final class Block {
    let bytes = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: GzipStream.readBytes)
    var baseAddress: UnsafeMutablePointer<UInt8>? { bytes.baseAddress }
    var count: Int { bytes.count }
    func prefix(_ count: Int) -> UnsafeMutableBufferPointer<UInt8>.SubSequence {
        bytes.prefix(count)
    }
    deinit { bytes.deallocate() }
}

private func isBlank(_ bytes: ArraySlice<UInt8>) -> Bool {
    bytes.allSatisfy { [9, 10, 13, 32].contains($0) }
}

/// Where `needle` first is in `bytes`.
private func range(of needle: [UInt8], in bytes: ArraySlice<UInt8>) -> Range<Int>? {
    guard !needle.isEmpty, bytes.count >= needle.count else { return nil }
    var start = bytes.startIndex
    while let first = bytes[start...].firstIndex(of: needle[0]) {
        let end = first + needle.count
        if end > bytes.endIndex { return nil }
        if bytes[first..<end].elementsEqual(needle) { return first..<end }
        start = first + 1
    }
    return nil
}
