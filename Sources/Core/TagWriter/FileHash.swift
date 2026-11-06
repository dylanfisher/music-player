import CommonCrypto
import Darwin
import Metadata

/// SHA-256 of a whole file and of its audio payload, from one pass over it, and of the file as
/// a write in place would leave it.
struct FileHashes: Equatable {
    var full: [UInt8]
    var payload: [UInt8]
    /// The whole file with `replacing`'s bytes instead of its own, when asked for.
    var edited: [UInt8]?
}

/// How much one read takes while hashing.
private let hashReadBytes = 4 * 1024 * 1024

/// Hashes the file at `path` and, separately, the bytes in `payload`, which must be sorted;
/// with `replacing`, also the file with those bytes at that offset instead of its own.
func fileHashes(
    _ path: String, payload: [Range<Int>], replacing: (offset: Int, bytes: [UInt8])? = nil
) throws(TagWriteError) -> FileHashes {
    let descriptor = open(path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw systemError(path, .unreadable, FileFailure.open) }
    defer { close(descriptor) }
    var full = CC_SHA256_CTX()
    var audio = CC_SHA256_CTX()
    var edited = CC_SHA256_CTX()
    CC_SHA256_Init(&full)
    CC_SHA256_Init(&audio)
    CC_SHA256_Init(&edited)
    let replaced = replacing.map { $0.offset..<$0.offset + $0.bytes.count }
    var buffer = [UInt8](repeating: 0, count: hashReadBytes)
    var offset = 0
    while true {
        let count = buffer.withUnsafeMutableBytes {
            pread(descriptor, $0.baseAddress, hashReadBytes, off_t(offset))
        }
        if count < 0 {
            if errno == EINTR { continue }
            throw systemError(path, .unreadable, FileFailure.read)
        }
        if count == 0 { break }
        let chunk = offset..<offset + count
        buffer.withUnsafeBytes { raw in
            _ = CC_SHA256_Update(&full, raw.baseAddress, CC_LONG(count))
            for range in payload {
                let overlap = range.clamped(to: chunk)
                guard !overlap.isEmpty else { continue }
                _ = CC_SHA256_Update(
                    &audio, raw.baseAddress! + (overlap.lowerBound - offset), CC_LONG(overlap.count)
                )
            }
        }
        if let replacing, let replaced {
            let overlap = replaced.clamped(to: chunk)
            if !overlap.isEmpty {
                let from = overlap.lowerBound - replaced.lowerBound
                buffer.replaceSubrange(
                    overlap.lowerBound - offset..<overlap.upperBound - offset,
                    with: replacing.bytes[from..<from + overlap.count])
            }
            buffer.withUnsafeBytes { _ = CC_SHA256_Update(&edited, $0.baseAddress, CC_LONG(count)) }
        }
        offset += count
    }
    var fullDigest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    var audioDigest = fullDigest
    var editedDigest = fullDigest
    CC_SHA256_Final(&fullDigest, &full)
    CC_SHA256_Final(&audioDigest, &audio)
    CC_SHA256_Final(&editedDigest, &edited)
    return FileHashes(
        full: fullDigest, payload: audioDigest, edited: replacing == nil ? nil : editedDigest)
}

/// A failed system call, with `errno`'s message.
/// A full disk is reported as one whatever the step, so a batch stops on it.
func systemError(_ path: String, _ kind: TagWriteError.Kind, _ what: String) -> TagWriteError {
    let full = errno == ENOSPC || errno == EDQUOT
    return TagWriteError(
        path: path, kind: full ? .diskFull : kind,
        detail: "\(what): \(String(cString: strerror(errno)))")
}
