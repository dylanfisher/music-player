import Darwin
import Foundation

/// The sync folder, opened once for a pass. Every log is opened in its descriptor without
/// following a link, so a folder or a log swapped for a link mid-pass is refused, not followed
/// (ADR 0025, ADR 0038).
final class SyncDirectory {
    /// How many other machines' logs a pass reads; the rest are reported.
    static let maximumLogs = 64

    let path: String
    private let descriptor: Int32

    init(path: String) throws(SyncFileError) {
        self.path = path
        descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw .open(path, errno) }
    }

    deinit { close(descriptor) }

    /// The name of the log of the machine `id`.
    static func logName(_ id: String) -> String { id + logSuffix }

    /// The machine whose log `name` is, for a name of 32 lowercase hex digits and `.log`.
    static func machine(ofLog name: String) -> String? {
        guard name.hasSuffix(logSuffix) else { return nil }
        let id = String(name.dropLast(logSuffix.count))
        return isSyncID(id) ? id : nil
    }

    /// Every name in the folder that's a machine's log, sorted.
    func logNames() throws(SyncFileError) -> [String] {
        let copy = dup(descriptor)
        guard copy >= 0, let directory = fdopendir(copy) else {
            let failure = errno
            if copy >= 0 { close(copy) }
            throw .list(path, failure)
        }
        defer { closedir(directory) }
        rewinddir(directory)
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if Self.machine(ofLog: name) != nil { names.append(name) }
        }
        return names.sorted()
    }

    /// Opens the log `name` to read, as a regular file.
    func openForReading(_ name: String) throws(SyncFileError) -> SyncLogFile {
        try SyncLogFile(
            openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC), name: name,
            in: path, writing: false)
    }

    /// Opens this machine's log `name` to append to, making it when it isn't there. It must
    /// be a regular file of this user with one link, so no other file is written through it.
    func openForAppending(_ name: String) throws(SyncFileError) -> SyncLogFile {
        try SyncLogFile(
            openat(
                descriptor, name, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC,
                0o644), name: name, in: path, writing: true)
    }
}

private let logSuffix = ".log"

/// A log in the sync folder, read and written through its descriptor.
final class SyncLogFile {
    let name: String
    /// The size when it was opened.
    let size: Int
    private let descriptor: Int32

    fileprivate init(_ descriptor: Int32, name: String, in folder: String, writing: Bool)
        throws(SyncFileError)
    {
        self.name = name
        guard descriptor >= 0 else { throw .open(folder + "/" + name, errno) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let failure = errno
            close(descriptor)
            throw .open(folder + "/" + name, failure)
        }
        let problem: String? =
            if info.st_mode & S_IFMT != S_IFREG {
                "isn't a regular file"
            } else if writing, info.st_nlink != 1 {
                "has \(info.st_nlink) links"
            } else if writing, info.st_uid != geteuid() {
                "belongs to another user"
            } else {
                nil
            }
        let flags = fcntl(descriptor, F_GETFL)
        guard problem == nil, flags >= 0, fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0
        else {
            close(descriptor)
            throw .refused(folder + "/" + name, problem ?? "can't be read")
        }
        self.descriptor = descriptor
        size = Int(info.st_size)
    }

    deinit { close(descriptor) }

    /// The bytes in `range`, which must be inside the file as it was opened.
    func read(_ range: Range<Int>) throws(SyncFileError) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: range.count)
        var done = 0
        while done < range.count {
            let count = bytes.withUnsafeMutableBytes { raw in
                pread(
                    descriptor, raw.baseAddress! + done, range.count - done,
                    off_t(range.lowerBound + done))
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw .read(name, count < 0 ? errno : 0) }
            done += count
        }
        return bytes
    }

    /// Appends all of `bytes`.
    func append(_ bytes: [UInt8]) throws(SyncFileError) {
        var done = 0
        while done < bytes.count {
            let count = bytes.withUnsafeBytes { raw in
                write(descriptor, raw.baseAddress! + done, bytes.count - done)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw .write(name, errno) }
            done += count
        }
    }
}

/// What went wrong with the sync folder or a log in it.
enum SyncFileError: Error, Equatable, CustomStringConvertible {
    case open(String, Int32)
    case list(String, Int32)
    case refused(String, String)
    case read(String, Int32)
    case write(String, Int32)
    /// This machine's log in the folder doesn't match what it logged: some other process wrote
    /// or cut it, or another Mac uses this machine's ID.
    case notOurs(String, String)

    var description: String {
        switch self {
        case .open(let path, let code): "can't open \(path): \(String(cString: strerror(code)))"
        case .list(let path, let code): "couldn't list \(path): \(String(cString: strerror(code)))"
        case .refused(let path, let reason): "\(path) \(reason), so it isn't used"
        case .read(let name, let code):
            "reading \(name) failed: \(code == 0 ? "it got shorter" : String(cString: strerror(code)))"
        case .write(let name, let code):
            "writing \(name) failed: \(String(cString: strerror(code)))"
        case .notOurs(let name, let reason):
            "\(name) isn't what this Mac logged (\(reason)), so it isn't written; another"
                + " program or another Mac with this one's library wrote it"
        }
    }
}
