import CommonCrypto
import Darwin
import Foundation
import Metadata

/// SHA-256 of a whole file and of its audio payload, from one pass over it.
struct FileHashes: Equatable {
    var full: [UInt8]
    var payload: [UInt8]
}

/// How much one read takes while hashing.
private let hashReadBytes = 4 * 1024 * 1024

/// The whole-file and payload digests of a file, fed its bytes in order, a block at a time.
struct FileHasher {
    private var full = CC_SHA256_CTX()
    private var audio = CC_SHA256_CTX()
    /// The audio's ranges, sorted.
    private let payload: [Range<Int>]
    /// Where the next block must start: the bytes so far, from the file's start.
    private(set) var offset = 0

    init(payload: [Range<Int>]) {
        self.payload = payload
        CC_SHA256_Init(&full)
        CC_SHA256_Init(&audio)
    }

    /// Adds the file's next bytes, which start at `offset`.
    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        let block = offset..<offset + bytes.count
        _ = CC_SHA256_Update(&full, bytes.baseAddress, CC_LONG(bytes.count))
        for range in payload {
            let overlap = range.clamped(to: block)
            guard !overlap.isEmpty else { continue }
            _ = CC_SHA256_Update(
                &audio, bytes.baseAddress! + (overlap.lowerBound - offset), CC_LONG(overlap.count))
        }
        offset = block.upperBound
    }

    /// Reads `descriptor` from `offset` up to `end`, or to the end of the file when nil, and
    /// hashes what it reads; `path` names the file in a failure. A file that ends before `end`
    /// fails as changed during the write.
    mutating func hash(
        _ descriptor: Int32, upTo end: Int?, _ path: String, faults: WriteFaults
    ) throws(TagWriteError) {
        // A copy asks for the bytes before each range it keeps, most often none.
        if let end, end <= offset { return }
        // Not zeroed: only the bytes a read fills are hashed, and a write hashes more than once,
        // so a small file would otherwise pay to zero all of it each time.
        var buffer = [UInt8](unsafeUninitializedCapacity: hashReadBytes) { _, count in
            count = hashReadBytes
        }
        while end.map({ offset < $0 }) ?? true {
            let want = min(hashReadBytes, (end ?? .max) - offset)
            let count = buffer.withUnsafeMutableBytes {
                pread(descriptor, $0.baseAddress, want, off_t(offset))
            }
            faults.called(.read(bytes: max(count, 0)))
            if count < 0 {
                if errno == EINTR { continue }
                throw systemError(path, .unreadable, FileFailure.read)
            }
            if count == 0 {
                if end == nil { return }
                throw TagWriteError(path: path, kind: .changedDuringWrite, detail: shorterDetail)
            }
            buffer.withUnsafeBytes { update(UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
        }
    }

    /// The digests; the hasher takes no more bytes after.
    mutating func finish() -> FileHashes {
        var fullDigest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        var audioDigest = fullDigest
        CC_SHA256_Final(&fullDigest, &full)
        CC_SHA256_Final(&audioDigest, &audio)
        return FileHashes(full: fullDigest, payload: audioDigest)
    }
}

/// Hashes the file at `path` and, separately, the bytes in `payload`, which must be sorted.
func fileHashes(_ path: String, payload: [Range<Int>], faults: WriteFaults)
    throws(TagWriteError) -> FileHashes
{
    faults.called(.open)
    let descriptor = open(path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw systemError(path, .unreadable, FileFailure.open) }
    defer {
        faults.called(.close)
        close(descriptor)
    }
    var hasher = FileHasher(payload: payload)
    try hasher.hash(descriptor, upTo: nil, path, faults: faults)
    return hasher.finish()
}

let shorterDetail = "the file got shorter while copying"

/// The SHA-256 of `bytes`, such as a write in place's region.
func sha256(_ bytes: [UInt8]) -> Data {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    _ = CC_SHA256(bytes, CC_LONG(bytes.count), &digest)
    return Data(digest)
}

/// A failed system call, with `errno`'s message.
/// A full disk is reported as one whatever the step, so a batch stops on it.
func systemError(_ path: String, _ kind: TagWriteError.Kind, _ what: String) -> TagWriteError {
    let full = errno == ENOSPC || errno == EDQUOT
    return TagWriteError(
        path: path, kind: full ? .diskFull : kind,
        detail: "\(what): \(String(cString: strerror(errno)))")
}
