import Darwin
import Foundation

/// A Unix-domain socket that only this user can reach: it lives in a folder of this user's with
/// no access for anyone else, the socket itself is 0600, and every connection's peer must run
/// as `allowedUID`, so even a socket opened up by mistake answers nobody else. Each request is
/// one frame of at most `requestCap` bytes, read within `timeoutSeconds`.
///
/// One thread accepts and reads connections in turn, blocked in `poll` while none come, so an
/// idle server costs no wakeups. A slow client holds the next one for at most the timeout.
public final class LocalSocketServer: Sendable {
    /// Gets each request and answers it through the reply, from any thread, once.
    public typealias Handler = @Sendable (Data, LocalSocketReply) -> Void

    public let path: String
    let listener: Int32
    /// Written to by `stop`, to wake the thread from `poll`.
    private let wakeRead: Int32
    private let wakeWrite: Int32
    /// The socket file's inode, so the server removes only the file it made.
    private let inode: ino_t
    private let state = ServerState()
    /// Replies handed out and not yet sent, past which a connection is refused unread.
    private let pending: PendingReplies
    /// Left when the thread finishes, so any number of `stop` calls can wait for it.
    private let finished = DispatchGroup()

    /// `problem` hears each connection refused or dropped, and why. At most `pendingCap`
    /// replies may be outstanding at once.
    public init(
        path: String, allowedUID: uid_t = geteuid(), requestCap: Int, timeoutSeconds: Double,
        pendingCap: Int = 16, problem: @escaping @Sendable (LocalSocketError) -> Void,
        handler: @escaping Handler
    ) throws(LocalSocketError) {
        guard let address = socketAddress(path) else { throw .pathTooLong(path) }
        try Self.prepareFolder((path as NSString).deletingLastPathComponent)
        try Self.removeStale(path, address: address)
        let (fd, inode) = try Self.listen(at: path, address: address)
        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else {
            let code = errno
            close(fd)
            Self.removeSocket(path, inode: inode)
            throw .system("pipe", errno: code)
        }
        self.path = path
        self.inode = inode
        listener = fd
        wakeRead = pipeFDs[0]
        wakeWrite = pipeFDs[1]
        pending = PendingReplies(cap: pendingCap)
        finished.enter()
        let thread = Thread { [self] in
            run(
                allowedUID: allowedUID, requestCap: requestCap, timeoutSeconds: timeoutSeconds,
                problem: problem, handler: handler)
        }
        thread.name = "LocalSocketServer"
        thread.start()
    }

    /// Binds and listens at `path`. A failure removes only a socket this call bound, so losing
    /// a race to another server leaves the winner's socket alone.
    static func listen(at path: String, address: sockaddr_un) throws(LocalSocketError) -> (
        Int32, ino_t
    ) {
        let fd = try unixSocket()
        var bound: ino_t?
        do {
            guard withSocketAddress(address, { bind(fd, $0, $1) }) == 0 else {
                throw LocalSocketError.system("bind", errno: errno)
            }
            var info = stat()
            guard lstat(path, &info) == 0 else {
                throw LocalSocketError.system("lstat", errno: errno)
            }
            bound = info.st_ino
            // The folder already keeps others out; this keeps the socket closed too, should the
            // folder ever be opened up.
            guard chmod(path, 0o600) == 0 else {
                throw LocalSocketError.system("chmod", errno: errno)
            }
            guard Darwin.listen(fd, 16) == 0 else {
                throw LocalSocketError.system("listen", errno: errno)
            }
            return (fd, info.st_ino)
        } catch let error as LocalSocketError {
            close(fd)
            if let bound { removeSocket(path, inode: bound) }
            throw error
        } catch {
            preconditionFailure("only socket errors are thrown here: \(error)")
        }
    }

    /// Unlinks `path` only while it's still the file with `inode`.
    private static func removeSocket(_ path: String, inode: ino_t) {
        var info = stat()
        if lstat(path, &info) == 0, info.st_ino == inode { unlink(path) }
    }

    /// Stops accepting, removes the socket file and returns once the thread has finished,
    /// however often it's called and whether or not the thread ended on its own first.
    /// Replies already handed out can still be sent.
    public func stop() {
        state.lock.withLock {
            // While the thread runs it can't close the pipe, which it does under this lock.
            guard state.isRunning else { return }
            var byte = UInt8(0)
            _ = write(wakeWrite, &byte, 1)
        }
        finished.wait()
    }

    /// Ends the thread as a failure of `poll` would, for tests of `stop` after that.
    func endThreadForTests() {
        state.lock.withLock {
            guard state.isRunning else { return }
            var byte = UInt8(1)
            _ = write(wakeWrite, &byte, 1)
        }
        finished.wait()
    }

    private func run(
        allowedUID: uid_t, requestCap: Int, timeoutSeconds: Double,
        problem: @Sendable (LocalSocketError) -> Void, handler: Handler
    ) {
        defer {
            state.lock.withLock {
                state.isRunning = false
                Self.removeSocket(path, inode: inode)
                close(listener)
                close(wakeRead)
                close(wakeWrite)
            }
            finished.leave()
        }
        while true {
            var entries = [
                pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
            ]
            if poll(&entries, 2, -1) < 0 {
                if errno == EINTR { continue }
                problem(.system("poll", errno: errno))
                return
            }
            if entries[1].revents != 0 {
                var byte = UInt8(0)
                if read(wakeRead, &byte, 1) == 1, byte != 0 { problem(.closed) }
                return
            }
            guard entries[0].revents != 0 else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else {
                if errno != EINTR, errno != ECONNABORTED {
                    problem(.system("accept", errno: errno))
                }
                continue
            }
            guard let slot = pending.take() else {
                close(client)
                problem(.busy(pending.cap))
                continue
            }
            do {
                try prepareConnection(client)
                let uid = try peerUID(client)
                guard uid == allowedUID else { throw LocalSocketError.otherUser(uid) }
                let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutSeconds * 1e9)
                let request = try LocalSocketFrame.read(client, cap: requestCap, deadline: deadline)
                handler(
                    request,
                    LocalSocketReply(fd: client, timeoutSeconds: timeoutSeconds, slot: slot))
            } catch let error as LocalSocketError {
                close(client)
                slot.release()
                problem(error)
            } catch {
                preconditionFailure("only socket errors are thrown here: \(error)")
            }
        }
    }

    /// Makes `folder` with no access for anyone else, or checks that it already is so: a
    /// folder, not a link, of this user's, closed to group and others.
    static func prepareFolder(_ folder: String) throws(LocalSocketError) {
        if mkdir(folder, 0o700) != 0, errno != EEXIST { throw .system("mkdir", errno: errno) }
        let fd = open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw .unsafeFolder(folder, reason: "is a link or a file, not a folder")
            }
            throw .system("open", errno: errno)
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw .system("fstat", errno: errno) }
        guard info.st_uid == geteuid() else {
            throw .unsafeFolder(folder, reason: "belongs to user \(info.st_uid), not this user")
        }
        guard info.st_mode & 0o077 == 0 else {
            throw .unsafeFolder(
                folder,
                reason: "is open to other users (mode \(String(info.st_mode & 0o777, radix: 8)));"
                    + " it must be 700")
        }
    }

    /// Removes a socket an earlier run left, after checking nothing answers on it.
    private static func removeStale(_ path: String, address: sockaddr_un) throws(LocalSocketError) {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return }
            throw .system("lstat", errno: errno)
        }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid() else {
            throw .notASocket(path)
        }
        let probe = try unixSocket()
        let answered = withSocketAddress(address) { connect(probe, $0, $1) } == 0
        close(probe)
        if answered { throw .inUse(path) }
        guard unlink(path) == 0 else { throw .system("unlink", errno: errno) }
    }
}

/// The way back to one client. `send` writes the reply and closes the connection; a reply
/// dropped unsent closes it with nothing.
/// `isSent` is guarded by `lock`.
public final class LocalSocketReply: @unchecked Sendable {
    private let fd: Int32
    private let timeoutSeconds: Double
    private let slot: PendingReplies.Slot
    private let lock = NSLock()
    private var isSent = false

    init(fd: Int32, timeoutSeconds: Double, slot: PendingReplies.Slot) {
        self.fd = fd
        self.timeoutSeconds = timeoutSeconds
        self.slot = slot
    }

    deinit {
        if !isSent {
            close(fd)
            slot.release()
        }
    }

    public func send(_ data: Data) throws(LocalSocketError) {
        let first = lock.withLock {
            defer { isSent = true }
            return !isSent
        }
        precondition(first, "a reply is sent once")
        defer {
            close(fd)
            slot.release()
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutSeconds * 1e9)
        try LocalSocketFrame.write(fd, data, deadline: deadline)
    }
}

/// Whether the server's thread still runs, which decides whether `stop` may write to its pipe.
/// `isRunning` is guarded by `lock`.
private final class ServerState: @unchecked Sendable {
    let lock = NSLock()
    var isRunning = true
}

/// Counts replies handed out and not yet sent, so clients that never read can't hold
/// descriptors without bound.
/// `count` is guarded by `lock`.
final class PendingReplies: @unchecked Sendable {
    let cap: Int
    private let lock = NSLock()
    private var count = 0

    init(cap: Int) { self.cap = cap }

    /// One reply's place, given back once.
    /// `isReleased` is guarded by `lock`.
    final class Slot: @unchecked Sendable {
        private let owner: PendingReplies
        private let lock = NSLock()
        private var isReleased = false

        init(_ owner: PendingReplies) { self.owner = owner }

        func release() {
            let first = lock.withLock {
                defer { isReleased = true }
                return !isReleased
            }
            if first { owner.lock.withLock { owner.count -= 1 } }
        }
    }

    /// A place, or nil when `cap` are taken.
    func take() -> Slot? {
        lock.withLock {
            guard count < cap else { return nil }
            count += 1
            return Slot(self)
        }
    }
}
