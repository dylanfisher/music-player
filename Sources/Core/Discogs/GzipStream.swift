import CommonCrypto
import Darwin
import Foundation
import zlib

/// A gzip file read as its inflated bytes (ADR 0130): nothing is unpacked to disk, and the
/// compressed bytes are hashed and counted as they're read, so the file is read once. Belongs
/// to the thread that reads it.
final class GzipStream {
    /// How much one read of the file takes.
    static let readBytes = 1 << 20

    let url: URL
    /// The compressed bytes read so far.
    private(set) var compressedBytesRead = 0
    /// Why the stream stopped before the end of its gzip data, once it has.
    private(set) var failure: CatalogImportError?

    private let descriptor: Int32
    private var zlibStream = z_stream()
    private let input = UnsafeMutablePointer<UInt8>.allocate(capacity: GzipStream.readBytes)
    private var digest = CC_SHA256_CTX()
    /// Whether the last member's trailer was read and no data follows it.
    private var ended = false

    init(file url: URL) throws {
        self.url = url
        descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            input.deallocate()
            throw CatalogImportError.unreadable(
                url.lastPathComponent, String(cString: strerror(errno)))
        }
        // 15 + 16: the largest window, and gzip's header and trailer rather than zlib's.
        let result = inflateInit2_(
            &zlibStream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard result == Z_OK else { preconditionFailure("inflateInit2 returned \(result)") }
        CC_SHA256_Init(&digest)
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
            let result = inflate(&zlibStream, Z_NO_FLUSH)
            switch result {
            case Z_OK, Z_BUF_ERROR: continue
            case Z_STREAM_END:
                // A gzip file may hold several members one after another.
                if zlibStream.avail_in == 0 {
                    let count = fill()
                    if count < 0 { return -1 }
                    if count == 0 {
                        ended = true
                        return room - Int(zlibStream.avail_out)
                    }
                }
                inflateReset(&zlibStream)
            default:
                let message = zlibStream.msg.map { String(cString: $0) } ?? "zlib error \(result)"
                failure = .corrupt(url.lastPathComponent, message)
                return -1
            }
        }
        return room - Int(zlibStream.avail_out)
    }

    /// Reads the next block of the file into `input`, hashing it: the bytes read, 0 at the
    /// end of the file, or -1 with `failure` set.
    private func fill() -> Int {
        while true {
            let count = Darwin.read(descriptor, input, Self.readBytes)
            if count < 0, errno == EINTR { continue }
            if count < 0 {
                failure = .unreadable(url.lastPathComponent, String(cString: strerror(errno)))
                return -1
            }
            compressedBytesRead += count
            CC_SHA256_Update(&digest, input, CC_LONG(count))
            zlibStream.next_in = input
            zlibStream.avail_in = UInt32(count)
            return count
        }
    }

}
