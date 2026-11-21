import Foundation
import zlib

/// A reply's body gzipped in memory with the system zlib, in one call: the remote's replies are
/// at most a few hundred kilobytes, so `deflateBound` sizes the output once.
func gzip(_ bytes: [UInt8]) -> [UInt8] {
    var stream = z_stream()
    // Level 6, zlib's default; window bits 15 + 16 for gzip's header and trailer.
    let started = deflateInit2_(
        &stream, 6, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
        Int32(MemoryLayout<z_stream>.size))
    guard started == Z_OK else { preconditionFailure("deflateInit2 returned \(started)") }
    defer { deflateEnd(&stream) }
    // gzip's header and trailer are 18 bytes past the deflate stream that `deflateBound` sizes.
    var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, UInt(bytes.count))) + 18)
    var input = bytes
    let written = input.withUnsafeMutableBufferPointer { source in
        output.withUnsafeMutableBufferPointer { target in
            stream.next_in = source.baseAddress
            stream.avail_in = UInt32(source.count)
            stream.next_out = target.baseAddress
            stream.avail_out = UInt32(target.count)
            let result = deflate(&stream, Z_FINISH)
            guard result == Z_STREAM_END else {
                preconditionFailure("deflate returned \(result) with room for the whole output")
            }
            return target.count - Int(stream.avail_out)
        }
    }
    return Array(output.prefix(written))
}

/// The content coding `gzip` makes, as `Accept-Encoding` and `Content-Encoding` name it.
let gzipCoding = "gzip"

/// Whether an `Accept-Encoding` value takes gzip: it's listed, without `q=0`.
func acceptsGzip(_ value: String) -> Bool {
    value.split(separator: ",").contains { part in
        let pieces = part.split(separator: ";").map {
            $0.trimmingCharacters(in: [" ", "\t"]).lowercased()
        }
        guard pieces.first == gzipCoding else { return false }
        return !pieces.dropFirst().contains { $0 == "q=0" || $0 == "q=0.0" || $0 == "q=0.00" }
    }
}
