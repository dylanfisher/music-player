import Foundation

/// A dump's inflated bytes cut into batches of whole records, each wrapped in the dump's root
/// element so `XMLParser` reads it as a document of its own (ADR 0130). `XMLParser` keeps what
/// it autoreleases until its parse returns, so one parse over a whole dump would hold a string
/// for every element it read; a batch parsed in an autorelease pool of its own gives them all
/// back. The dumps write each record on a line of its own, so a record ends where its closing
/// tag ends a line; text can't hold a tag, as XML escapes its `<`. A dump laid out otherwise
/// fails to parse rather than being read wrong. A batch also ends at the first record end past
/// the stream's access point, once it has one, so a checkpoint can be taken there (ADR 0134).
struct DumpBatches {
    /// About how much a batch holds: the records that end in it, past this many bytes.
    static let batchBytes = 4 << 20
    /// How much a read takes once the stream has an access point, to reach the record end
    /// after it: a few of the dumps' records.
    static let pastAccessPointBytes = 32 << 10
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
    /// The inflated offset in the file the buffer starts at.
    private var offset: Int
    /// The inflated bytes still to drop before the buffer starts: those a resume reads again
    /// between its access point and the record it starts at.
    private var skip = 0

    /// `batchBytes` is for tests, which cut their small dumps into many batches. `resuming`
    /// carries on from a checkpoint: `stream` starts at its access point, and the batches at
    /// the record after it.
    init(
        _ stream: GzipStream, kind: DumpKind, file: String, batchBytes: Int = batchBytes,
        resuming position: DumpPosition? = nil
    ) {
        self.stream = stream
        self.batchBytes = batchBytes
        self.kind = kind
        self.file = file
        rootStart = Array("<\(kind.rawValue)>".utf8)
        rootEnd = Array("</\(kind.rawValue)>".utf8)
        recordEnd = Array("</\(DumpElement(record: kind).rawValue)>\n".utf8)
        buffer.reserveCapacity(Self.batchBytes + GzipStream.readBytes)
        offset = stream.inflatedBytes
        if let position {
            started = true
            line = position.line
            skip = position.offset - offset
        }
    }

    /// The next batch, inside the root element; nil once the root has ended. Throws when the
    /// stream fails, or the bytes aren't a dump of whole records.
    mutating func next() throws -> DumpBatch? {
        while true {
            if !started, let end = range(of: rootStart, in: buffer[...])?.upperBound {
                guard isBlank(buffer[..<end].dropLast(rootStart.count)) else {
                    throw malformed("text before <\(kind.rawValue)>")
                }
                consume(end)
                started = true
            }
            let read = try fill()
            if started, buffer.count >= batchBytes || read == 0 || isPast(stream.accessPoint),
                let end = lastRecordEnd()
            {
                let reachesPoint = isPast(stream.accessPoint, by: end)
                if buffer.count < batchBytes, read > 0, !reachesPoint { continue }
                let document = Data(rootStart) + Data(buffer[..<end]) + Data(rootEnd)
                let firstLine = line
                consume(end)
                return DumpBatch(
                    document: document, firstLine: firstLine,
                    end: DumpPosition(offset: offset, line: line),
                    accessPoint: reachesPoint ? stream.takeAccessPoint() : nil)
            }
            if read == 0 { return try finish() }
            if buffer.count > Self.largestRecordBytes {
                throw malformed(
                    "a record over \(Self.largestRecordBytes >> 20) MB, or no line breaks")
            }
        }
    }

    /// Whether the buffer's first `count` bytes, all of them by default, reach `point`.
    private func isPast(_ point: GzipAccessPoint?, by count: Int? = nil) -> Bool {
        guard let point else { return false }
        return offset + (count ?? buffer.count) >= point.inflatedOffset
    }

    /// At the end of the stream, with no whole record left: what's left must be the root's
    /// end tag.
    private mutating func finish() throws -> DumpBatch? {
        guard started else { throw malformed("no <\(kind.rawValue)>") }
        guard let end = range(of: rootEnd, in: buffer[...]),
            isBlank(buffer[..<end.lowerBound]), isBlank(buffer[end.upperBound...])
        else { throw malformed("the file ends inside a record") }
        buffer.removeAll()
        return nil
    }

    /// Reads another block of inflated bytes onto the buffer: how many, 0 at the end. With an
    /// access point waiting, a short one, so the batch ends just past it.
    private mutating func fill() throws -> Int {
        let length = stream.accessPoint == nil ? block.count : Self.pastAccessPointBytes
        let count = stream.read(block.baseAddress!, maxLength: length)
        guard count >= 0 else {
            throw stream.failure ?? CatalogImportError.unreadable(file, "the stream failed")
        }
        let dropped = min(skip, count)
        skip -= dropped
        offset += dropped
        buffer.append(contentsOf: block.prefix(count).dropFirst(dropped))
        return count
    }

    /// Drops the buffer's first `count` bytes, counting the lines they end.
    private mutating func consume(_ count: Int) {
        // memchr rather than a loop over each byte: this runs over every byte of the dump.
        line += buffer.withUnsafeBytes { bytes in
            guard count > 0, var cursor = bytes.baseAddress else { return 0 }
            let end = cursor + count
            var lines = 0
            while let newline = memchr(cursor, Int32(UInt8(ascii: "\n")), end - cursor) {
                lines += 1
                cursor = UnsafeRawPointer(newline) + 1
            }
            return lines
        }
        buffer.removeFirst(count)
        offset += count
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

/// Whole records of a dump, inside its root element, for one `XMLParser`.
struct DumpBatch {
    var document: Data
    /// The line of the file its first record is on.
    var firstLine: Int
    /// Where the record after its last starts.
    var end: DumpPosition
    /// The stream's access point when it's at or before `end`, so a checkpoint can be taken
    /// at `end`: handed over, so the stream starts looking for the next.
    var accessPoint: GzipAccessPoint?
}

/// A place in a dump between two records: its inflated offset in the file, and its line.
struct DumpPosition: Codable, Equatable, Sendable {
    var offset: Int
    var line: Int
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
