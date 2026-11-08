import Foundation
import zlib

/// Whole files to and from gzip with the system zlib, a chunk at a time, for the index's
/// snapshots (ADR 0142). The Discogs dumps' reader stays in `Discogs`: it hashes, counts and
/// resumes as it reads, which a snapshot needs none of.
enum GzipFile {
    /// How much is read from a file, and written, at a time.
    static let chunkBytes = 1 << 20
    /// zlib's default level: most of the size of level 9 at a fraction of the time.
    static let level: Int32 = 6
    /// 15 + 16: the largest window, with gzip's header and trailer rather than zlib's.
    private static let gzipWindowBits: Int32 = 15 + 16

    /// Writes `source` compressed to a new file at `destination`.
    static func compress(_ source: URL, to destination: URL) throws(SnapshotError) {
        var stream = z_stream()
        let started = deflateInit2_(
            &stream, level, Z_DEFLATED, gzipWindowBits, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size))
        guard started == Z_OK else { preconditionFailure("deflateInit2 returned \(started)") }
        defer { deflateEnd(&stream) }
        let files = try FilePair(source, destination)
        var finishing = false
        while !finishing {
            var input = try files.read()
            finishing = input.count < chunkBytes
            try input.withUnsafeMutableBufferPointer { (buffer) throws(SnapshotError) in
                stream.next_in = buffer.baseAddress
                stream.avail_in = UInt32(buffer.count)
                // Until deflate leaves room in the output: it has taken all the input then,
                // and when finishing, written the trailer.
                repeat {
                    stream.next_out = files.output
                    stream.avail_out = UInt32(chunkBytes)
                    let result = deflate(&stream, finishing ? Z_FINISH : Z_NO_FLUSH)
                    guard result != Z_STREAM_ERROR else {
                        preconditionFailure("deflate returned Z_STREAM_ERROR")
                    }
                    try files.write(chunkBytes - Int(stream.avail_out))
                } while stream.avail_out == 0
            }
        }
        try files.finish()
    }

    /// Writes `source`, a gzip file, uncompressed to a new file at `destination`. zlib checks
    /// the trailer's CRC and length; a file that ends early, or has bytes after its trailer,
    /// throws.
    static func decompress(_ source: URL, to destination: URL) throws(SnapshotError) {
        var stream = z_stream()
        let started = inflateInit2_(
            &stream, gzipWindowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard started == Z_OK else { preconditionFailure("inflateInit2 returned \(started)") }
        defer { inflateEnd(&stream) }
        let name = source.lastPathComponent
        let files = try FilePair(source, destination)
        var ended = false
        while true {
            var input = try files.read()
            if input.isEmpty { break }
            guard !ended else { throw .gzip(name, "it has data after its end") }
            try input.withUnsafeMutableBufferPointer { (buffer) throws(SnapshotError) in
                stream.next_in = buffer.baseAddress
                stream.avail_in = UInt32(buffer.count)
                repeat {
                    stream.next_out = files.output
                    stream.avail_out = UInt32(chunkBytes)
                    let result = inflate(&stream, Z_NO_FLUSH)
                    switch result {
                    case Z_OK, Z_BUF_ERROR: break
                    case Z_STREAM_END: ended = true
                    default:
                        throw .gzip(
                            name, stream.msg.map { String(cString: $0) } ?? "zlib error \(result)")
                    }
                    try files.write(chunkBytes - Int(stream.avail_out))
                } while stream.avail_out == 0 && !ended
                if ended, stream.avail_in > 0 { throw .gzip(name, "it has data after its end") }
            }
        }
        guard ended else { throw .gzip(name, "it ends early") }
        try files.finish()
    }
}

/// The file a gzip pass reads and the new one it writes, and the output buffer between.
private final class FilePair {
    let output = UnsafeMutablePointer<UInt8>.allocate(capacity: GzipFile.chunkBytes)
    private let source: URL
    private let destination: URL
    private let reader: FileHandle
    private let writer: FileHandle

    init(_ source: URL, _ destination: URL) throws(SnapshotError) {
        self.source = source
        self.destination = destination
        do {
            reader = try FileHandle(forReadingFrom: source)
        } catch {
            output.deallocate()
            throw .file(source.path, error.localizedDescription)
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
            let writer = FileHandle(forWritingAtPath: destination.path)
        else {
            output.deallocate()
            throw .file(destination.path, "it couldn't be made")
        }
        self.writer = writer
    }

    deinit {
        output.deallocate()
        try? reader.close()
        try? writer.close()
    }

    /// The next chunk of the source, shorter only at its end.
    func read() throws(SnapshotError) -> [UInt8] {
        do {
            return [UInt8](try reader.read(upToCount: GzipFile.chunkBytes) ?? Data())
        } catch {
            throw .file(source.path, error.localizedDescription)
        }
    }

    /// Appends the first `count` bytes of `output` to the destination.
    func write(_ count: Int) throws(SnapshotError) {
        guard count > 0 else { return }
        do {
            try writer.write(
                contentsOf: Data(bytesNoCopy: output, count: count, deallocator: .none))
        } catch {
            throw .file(destination.path, error.localizedDescription)
        }
    }

    /// Flushes the destination to the disk, so a rename after it can't leave a short file.
    func finish() throws(SnapshotError) {
        do {
            try writer.synchronize()
        } catch {
            throw .file(destination.path, error.localizedDescription)
        }
    }
}
