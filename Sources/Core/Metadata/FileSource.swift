import Darwin

/// The caching hints a tag read gives the volume. Each is a hint the volume may ignore, and on
/// SMB only the NAS can show what they save, so the scan can be run with each (ADR 0010).
public enum ReadHints: String, CaseIterable, Sendable {
    /// The volume reads ahead and caches as it likes.
    case none
    /// No read-ahead.
    case rdahead
    /// No read-ahead and no caching.
    case all
}

/// What the reader and the tag writer say when a file system call fails.
package enum FileFailure {
    package static let open = "can't open"
    package static let stat = "can't stat"
    package static let read = "read failed"
    package static let notRegular = "not a regular file"
}

/// A file opened once and read with `pread`, never mapped, so a slow NAS read stalls only the
/// caller and a file that shrinks fails the read instead of raising SIGBUS. Reads get exactly
/// the bytes asked for, and by default no read-ahead and no caching (ADR 0010).
package final class FileSource: ByteSource {
    package let size: Int
    let descriptor: Int32

    package init(path: String, hints: ReadHints = .all) throws(ParseFailure) {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw unreadable(nil, FileFailure.open) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let failure = unreadable(nil, FileFailure.stat)
            close(descriptor)
            throw failure
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw ParseFailure(kind: .unreadable, offset: nil, detail: FileFailure.notRegular)
        }
        // Tags are read in a few short reads spread over the file, so read-ahead would fetch
        // bytes the parser skips, and on a NAS that's transfer time, not a saved round trip.
        // Uncached, a full scan doesn't fill memory with every file's first 16 KiB. Both are
        // hints a volume may refuse, which costs nothing but the saving, so failure is ignored.
        if hints != .none { _ = fcntl(descriptor, F_RDAHEAD, 0) }
        if hints == .all { _ = fcntl(descriptor, F_NOCACHE, 1) }
        self.descriptor = descriptor
        size = Int(info.st_size)
    }

    deinit { close(descriptor) }

    package func read(_ range: Range<Int>) throws(ParseFailure) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: range.count)
        var done = 0
        var failure: ParseFailure?
        buffer.withUnsafeMutableBytes { raw in
            while done < range.count {
                let count = pread(
                    descriptor, raw.baseAddress! + done, range.count - done,
                    off_t(range.lowerBound + done))
                if count < 0 {
                    if errno == EINTR { continue }
                    failure = unreadable(range.lowerBound + done, FileFailure.read)
                    return
                }
                if count == 0 {
                    failure = ParseFailure(
                        kind: .unreadable, offset: range.lowerBound + done,
                        detail: "the file ended early; it was \(size) bytes when opened")
                    return
                }
                done += count
            }
        }
        if let failure { throw failure }
        return buffer
    }
}

/// A failed system call, with `errno`'s message.
private func unreadable(_ offset: Int?, _ what: String) -> ParseFailure {
    ParseFailure(
        kind: .unreadable, offset: offset, detail: "\(what): \(String(cString: strerror(errno)))")
}
