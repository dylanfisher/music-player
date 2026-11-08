import CommonCrypto
import Darwin
import Foundation
import zlib

/// A gzip file read as its inflated bytes (ADR 0130): nothing is unpacked to disk, and the
/// compressed bytes are hashed and counted as they're inflated, so the file is read once. It
/// notes an access point every `accessPointBytes` of input, or once asked for one (ADR 0134,
/// after zlib's `zran.c`), which a later stream resumes from. Belongs to the thread that reads
/// it.
final class GzipStream {
    /// How much one read of the file takes.
    static let readBytes = 1 << 20
    /// The most a deflate window holds: what inflating from an access point needs before it.
    static let windowBytes = 1 << 15

    let url: URL
    /// The compressed bytes read so far.
    private(set) var compressedBytesRead = 0
    /// The inflated bytes given out so far, from the start of the file.
    private(set) var inflatedBytes = 0
    /// The access point noted, until `takeAccessPoint()`.
    private(set) var accessPoint: GzipAccessPoint?
    /// Why the stream stopped before the end of its gzip data, once it has.
    private(set) var failure: CatalogImportError?

    private let descriptor: Int32
    private var zlibStream = z_stream()
    private let input = UnsafeMutablePointer<UInt8>.allocate(capacity: GzipStream.readBytes)
    /// The hash of the compressed bytes inflate has taken.
    private var digest = CC_SHA256_CTX()
    /// The compressed bytes inflate has taken, which the hash covers: where the stream is in
    /// the file, while `compressedBytesRead` runs up to a read ahead of it.
    private(set) var consumedBytes = 0
    /// The compressed bytes between two access points.
    private let accessPointBytes: Int
    /// Where in the input the next access point is wanted: at the first deflate block boundary
    /// after it.
    private var nextAccessPoint: Int
    /// Whether this member is raw deflate, as it is after a resume: its trailer is then this
    /// stream's to check, with `rawCRC` and `rawBaseBytes`.
    private var raw = false
    private var rawCRC: UInt32 = 0
    /// The member's inflated bytes before the resume.
    private var rawBaseBytes = 0
    /// Whether the last member's trailer was read and no data follows it.
    private var ended = false

    /// Opens `url` at its start, or at `point`, an access point an earlier stream of the same
    /// file noted. `accessPointBytes` is how much input goes between access points; by default
    /// there are none unless asked for.
    init(
        file url: URL, resumingAt point: GzipAccessPoint? = nil, accessPointBytes: Int = .max
    ) throws(CatalogImportError) {
        self.url = url
        self.accessPointBytes = accessPointBytes
        nextAccessPoint = point.map { $0.compressedOffset } ?? 0
        nextAccessPoint = nextAccessPoint.addingReportingOverflow(accessPointBytes).overflow
            ? .max : nextAccessPoint + accessPointBytes
        descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        // Every property is set by now, so `deinit` frees `input` after a throw.
        guard descriptor >= 0 else {
            throw .unreadable(url.lastPathComponent, String(cString: strerror(errno)))
        }
        // 15 + 16: the largest window, and gzip's header and trailer rather than zlib's; -15
        // is raw deflate, from the middle of a member.
        let result = inflateInit2_(
            &zlibStream, point == nil ? 15 + 16 : -15, ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size))
        guard result == Z_OK else { preconditionFailure("inflateInit2 returned \(result)") }
        guard let point else {
            CC_SHA256_Init(&digest)
            return
        }
        try resume(at: point)
    }

    deinit {
        inflateEnd(&zlibStream)
        input.deallocate()
        Darwin.close(descriptor)
    }

    /// The SHA-256 of the compressed bytes, in lowercase hex, once the stream has ended.
    func sha256() -> String {
        precondition(ended, "the hash is of the whole file")
        var bytes = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&bytes, &digest)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Whether every byte of the file was inflated, through the last member's trailer.
    var isComplete: Bool { ended }

    /// Asks for an access point at the next deflate block boundary, which `accessPoint`
    /// then holds.
    func requestAccessPoint() {
        nextAccessPoint = min(nextAccessPoint, consumedBytes)
    }

    /// The access point noted, handed over and forgotten; the next is `accessPointBytes` on.
    func takeAccessPoint() -> GzipAccessPoint? {
        guard let point = accessPoint else { return nil }
        accessPoint = nil
        let (next, overflow) = consumedBytes.addingReportingOverflow(accessPointBytes)
        nextAccessPoint = overflow ? .max : next
        return point
    }

    /// Inflates up to `length` bytes into `buffer`: the bytes inflated, 0 at the end of the
    /// gzip data, or -1 with `failure` set.
    func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength length: Int) -> Int {
        guard !ended, failure == nil, length > 0 else { return failure == nil ? 0 : -1 }
        zlibStream.next_out = buffer
        zlibStream.avail_out = UInt32(clamping: length)
        let room = Int(zlibStream.avail_out)
        while Int(zlibStream.avail_out) == room {
            if zlibStream.avail_in == 0 {
                let count = fill()
                if count < 0 { return -1 }
                if count == 0 {
                    // The file ended inside a member: before its trailer.
                    failure = .truncated(url.lastPathComponent)
                    return -1
                }
            }
            // Stopping at each block boundary while a point is due, as `zran.c` does always.
            let waiting = accessPoint == nil && nextAccessPoint != .max
            let result = inflateTaking(waiting ? Z_BLOCK : Z_NO_FLUSH)
            switch result {
            case Z_OK, Z_BUF_ERROR:
                // 128: just past a block's end or the header; 64: in the last block, which
                // has no block after it to start from. A point just past the header is left
                // for the block's end, so the read stops after some bytes, not before any.
                if waiting, consumedBytes >= nextAccessPoint, zlibStream.data_type & 128 != 0,
                    zlibStream.data_type & 64 == 0, raw || zlibStream.total_out > 0
                {
                    noteAccessPoint()
                }
                continue
            case Z_STREAM_END:
                if raw, !checkTrailer() { return -1 }
                // A gzip file may hold several members one after another.
                if zlibStream.avail_in == 0 {
                    let count = fill()
                    if count < 0 { return -1 }
                    if count == 0 {
                        ended = true
                        return room - Int(zlibStream.avail_out)
                    }
                }
                inflateReset2(&zlibStream, 15 + 16)
            default:
                let message = zlibStream.msg.map { String(cString: $0) } ?? "zlib error \(result)"
                failure = .corrupt(url.lastPathComponent, message)
                return -1
            }
        }
        return room - Int(zlibStream.avail_out)
    }

    /// Runs inflate once, hashing the compressed bytes it took, and counting those and the
    /// bytes it made.
    private func inflateTaking(_ flush: Int32) -> Int32 {
        let inputStart = zlibStream.next_in
        let inputBefore = Int(zlibStream.avail_in)
        let outputStart = zlibStream.next_out
        let outputBefore = Int(zlibStream.avail_out)
        let result = inflate(&zlibStream, flush)
        let taken = inputBefore - Int(zlibStream.avail_in)
        if taken > 0 { CC_SHA256_Update(&digest, inputStart, CC_LONG(taken)) }
        consumedBytes += taken
        let made = outputBefore - Int(zlibStream.avail_out)
        inflatedBytes += made
        if raw, made > 0 { rawCRC = UInt32(crc32(uLong(rawCRC), outputStart, uInt(made))) }
        return result
    }

    /// Notes where inflating could start again: the input taken, the bits of its last byte
    /// still to read, the window, and the hash and check so far.
    private func noteAccessPoint() {
        var window = [UInt8](repeating: 0, count: Self.windowBytes)
        var windowLength = UInt32(Self.windowBytes)
        guard inflateGetDictionary(&zlibStream, &window, &windowLength) == Z_OK else {
            preconditionFailure("inflateGetDictionary failed on a stream that's inflating")
        }
        accessPoint = GzipAccessPoint(
            inflatedOffset: inflatedBytes, compressedOffset: consumedBytes,
            bits: Int(zlibStream.data_type & 7), window: Data(window.prefix(Int(windowLength))),
            sha256State: withUnsafeBytes(of: digest) { Data($0) },
            crc: raw ? rawCRC : UInt32(truncatingIfNeeded: zlibStream.adler),
            memberBytes: (raw ? rawBaseBytes : 0) + Int(zlibStream.total_out))
    }

    /// Starts raw inflate at `point`: the file from its offset, the bits of the byte before
    /// it that are still to read, and the window and hash as they were.
    private func resume(at point: GzipAccessPoint) throws(CatalogImportError) {
        let name = url.lastPathComponent
        guard point.sha256State.count == MemoryLayout<CC_SHA256_CTX>.size,
            point.window.count <= Self.windowBytes, (0...7).contains(point.bits),
            point.compressedOffset >= (point.bits > 0 ? 1 : 0), point.inflatedOffset >= 0,
            point.memberBytes >= 0
        else { throw .corrupt(name, "the checkpoint's access point isn't one zlib can use") }
        point.sha256State.withUnsafeBytes { bytes in
            withUnsafeMutableBytes(of: &digest) { $0.copyMemory(from: bytes) }
        }
        if point.bits > 0 {
            var byte: UInt8 = 0
            let count = pread(descriptor, &byte, 1, off_t(point.compressedOffset - 1))
            guard count == 1 else {
                throw count < 0
                    ? .unreadable(name, String(cString: strerror(errno))) : .truncated(name)
            }
            guard inflatePrime(&zlibStream, Int32(point.bits), Int32(byte >> (8 - point.bits)))
                == Z_OK
            else { throw .corrupt(name, "inflatePrime failed") }
        }
        if !point.window.isEmpty {
            let result = point.window.withUnsafeBytes { window in
                inflateSetDictionary(
                    &zlibStream, window.bindMemory(to: UInt8.self).baseAddress,
                    UInt32(window.count))
            }
            guard result == Z_OK else { throw .corrupt(name, "inflateSetDictionary failed") }
        }
        guard lseek(descriptor, off_t(point.compressedOffset), SEEK_SET) >= 0 else {
            throw .unreadable(name, String(cString: strerror(errno)))
        }
        compressedBytesRead = point.compressedOffset
        consumedBytes = point.compressedOffset
        inflatedBytes = point.inflatedOffset
        raw = true
        rawCRC = point.crc
        rawBaseBytes = point.memberBytes
    }

    /// Reads and checks the gzip trailer after a raw member: the CRC-32 of its inflated
    /// bytes, and their count modulo 2^32. False with `failure` set when it doesn't match.
    private func checkTrailer() -> Bool {
        var trailer: [UInt8] = []
        while trailer.count < 8 {
            if zlibStream.avail_in == 0 {
                let count = fill()
                if count < 0 { return false }
                if count == 0 {
                    failure = .truncated(url.lastPathComponent)
                    return false
                }
            }
            let taken = min(8 - trailer.count, Int(zlibStream.avail_in))
            let start = zlibStream.next_in!
            trailer.append(contentsOf: UnsafeBufferPointer(start: start, count: taken))
            CC_SHA256_Update(&digest, start, CC_LONG(taken))
            consumedBytes += taken
            zlibStream.next_in = start + taken
            zlibStream.avail_in -= UInt32(taken)
        }
        func littleEndian(_ bytes: ArraySlice<UInt8>) -> UInt32 {
            bytes.reversed().reduce(0) { $0 << 8 | UInt32($1) }
        }
        let size = UInt32(truncatingIfNeeded: rawBaseBytes + Int(zlibStream.total_out))
        guard littleEndian(trailer[0..<4]) == rawCRC, littleEndian(trailer[4..<8]) == size else {
            failure = .corrupt(url.lastPathComponent, "incorrect data check")
            return false
        }
        raw = false
        return true
    }

    /// Reads the next block of the file into `input`: the bytes read, 0 at the end of the
    /// file, or -1 with `failure` set.
    private func fill() -> Int {
        while true {
            let count = Darwin.read(descriptor, input, Self.readBytes)
            if count < 0, errno == EINTR { continue }
            if count < 0 {
                failure = .unreadable(url.lastPathComponent, String(cString: strerror(errno)))
                return -1
            }
            compressedBytesRead += count
            zlibStream.next_in = input
            zlibStream.avail_in = UInt32(count)
            return count
        }
    }
}

/// A place in a gzip file that inflating can start again from (ADR 0134): a deflate block
/// boundary, the 32 KB inflated before it, and the stream's hash and check up to it.
struct GzipAccessPoint: Codable, Equatable, Sendable {
    /// The inflated bytes before it, from the start of the file.
    var inflatedOffset: Int
    /// The compressed bytes before it; with `bits`, the last of them is partly the next block.
    var compressedOffset: Int
    /// The bits of the last compressed byte still to read.
    var bits: Int
    var window: Data
    /// The compressed bytes' `CC_SHA256_CTX`, as its bytes.
    var sha256State: Data
    /// The member's CRC-32 and inflated bytes so far, for its trailer.
    var crc: UInt32
    var memberBytes: Int
}
