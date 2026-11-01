import CommonCrypto
import Darwin

/// SHA-256 of a whole file and of its audio payload, from one pass over it.
struct FileHashes: Equatable {
    var full: [UInt8]
    var payload: [UInt8]
}

/// How much one read takes while hashing.
private let hashReadBytes = 4 * 1024 * 1024

/// Hashes the file at `path` and, separately, the bytes in `payload`, which must be sorted.
func fileHashes(_ path: String, payload: [Range<Int>]) throws(TagWriteError) -> FileHashes {
    let descriptor = open(path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw systemError(path, .unreadable, "can't open") }
    defer { close(descriptor) }
    var full = CC_SHA256_CTX()
    var audio = CC_SHA256_CTX()
    CC_SHA256_Init(&full)
    CC_SHA256_Init(&audio)
    var buffer = [UInt8](repeating: 0, count: hashReadBytes)
    var offset = 0
    while true {
        let count = buffer.withUnsafeMutableBytes {
            pread(descriptor, $0.baseAddress, hashReadBytes, off_t(offset))
        }
        if count < 0 {
            if errno == EINTR { continue }
            throw systemError(path, .unreadable, "read failed")
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
        offset += count
    }
    var fullDigest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    var audioDigest = fullDigest
    CC_SHA256_Final(&fullDigest, &full)
    CC_SHA256_Final(&audioDigest, &audio)
    return FileHashes(full: fullDigest, payload: audioDigest)
}

/// A failed system call, with `errno`'s message.
/// A full disk is reported as one whatever the step, so a batch stops on it.
func systemError(_ path: String, _ kind: TagWriteError.Kind, _ what: String) -> TagWriteError {
    let full = errno == ENOSPC || errno == EDQUOT
    return TagWriteError(
        path: path, kind: full ? .diskFull : kind,
        detail: "\(what): \(String(cString: strerror(errno)))")
}
