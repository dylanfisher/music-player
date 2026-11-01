/// One line of a log, or one too long to read.
enum SyncLogLine: Equatable {
    /// Without its line break.
    case line([UInt8])
    /// Over `SyncRecord.maximumLineBytes`; skipped to its line break, never held whole.
    case tooLong(bytes: Int)
}

/// Reads a log's complete lines from an offset, a chunk at a time: a line without its line
/// break, which a machine that died while writing leaves, is left for the next read.
struct SyncLogLines {
    static let chunkBytes = 1 << 20

    /// Where the next unread line starts.
    private(set) var offset: Int
    private let end: Int
    private let maximumLine: Int
    private let read: (Range<Int>) throws -> [UInt8]
    /// Bytes from `bufferStart` on, read but not yet returned.
    private var buffer: [UInt8] = []
    private var bufferStart: Int

    /// Reads `end` bytes at most, from `offset`, through `read`.
    init(
        from offset: Int, end: Int, maximumLine: Int = SyncRecord.maximumLineBytes,
        read: @escaping (Range<Int>) throws -> [UInt8]
    ) {
        self.offset = offset
        self.end = end
        self.maximumLine = maximumLine
        self.read = read
        bufferStart = offset
    }

    /// The next complete line, or nil when none is left.
    mutating func next() throws -> SyncLogLine? {
        var searched = offset
        var skipped = false
        while true {
            let bufferEnd = bufferStart + buffer.count
            if let newline = buffer[(searched - bufferStart)...].firstIndex(of: 0x0A) {
                let lineEnd = bufferStart + newline
                let length = lineEnd - offset
                let line: SyncLogLine =
                    skipped || length > maximumLine
                    ? .tooLong(bytes: length)
                    : .line(Array(buffer[(offset - bufferStart)..<newline]))
                offset = lineEnd + 1
                return line
            }
            guard bufferEnd < end else { return nil }
            if bufferEnd - offset > maximumLine {
                // Too long to keep: only its line break is looked for now.
                skipped = true
                buffer = []
                bufferStart = bufferEnd
            } else if offset > bufferStart {
                buffer.removeFirst(offset - bufferStart)
                bufferStart = offset
            }
            searched = bufferEnd
            buffer += try read(bufferEnd..<min(bufferEnd + Self.chunkBytes, end))
        }
    }
}
