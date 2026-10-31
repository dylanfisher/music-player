import Darwin

/// A file opened once and read with `pread`, never mapped, so a slow NAS read stalls only the
/// caller and a file that shrinks fails the read instead of raising SIGBUS.
final class FileSource: ByteSource {
    let size: Int
    private let descriptor: Int32

    init(path: String) throws(ParseFailure) {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw unreadable(nil, "can't open") }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let failure = unreadable(nil, "can't stat")
            close(descriptor)
            throw failure
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw ParseFailure(kind: .unreadable, offset: nil, detail: "not a regular file")
        }
        self.descriptor = descriptor
        size = Int(info.st_size)
    }

    deinit { close(descriptor) }

    func read(_ range: Range<Int>) throws(ParseFailure) -> [UInt8] {
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
                    failure = unreadable(range.lowerBound + done, "read failed")
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
