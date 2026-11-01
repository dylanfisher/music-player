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
    private let listener: Int32
    /// Written to by `stop`, to wake the thread from `poll`.
    private let wakeRead: Int32
    private let wakeWrite: Int32
    /// The socket file's inode, so `stop` removes only the file this server made.
    private let inode: ino_t
    private let stopped = DispatchSemaphore(value: 0)

    /// `problem` hears each connection refused or dropped, and why.
    public init(
        path: String, allowedUID: uid_t = geteuid(), requestCap: Int, timeoutSeconds: Double,
        problem: @escaping @Sendable (LocalSocketError) -> Void, handler: @escaping Handler
    ) throws(LocalSocketError) {
        guard let address = socketAddress(path) else { throw .pathTooLong(path) }
        try Self.prepareFolder((path as NSString).deletingLastPathComponent)
        try Self.removeStale(path, address: address)
        let fd = try unixSocket()
        var pipeFDs: [Int32] = [0, 0]
        do {
            guard withSocketAddress(address, { bind(fd, $0, $1) }) == 0 else {
                throw LocalSocketError.system("bind", errno: errno)
            }
            // The folder already keeps others out; this keeps the socket closed too, should the
            // folder ever be opened up.
            guard chmod(path, 0o600) == 0 else {
                throw LocalSocketError.system("chmod", errno: errno)
            }
            var info = stat()
            guard lstat(path, &info) == 0 else {
                throw LocalSocketError.system("lstat", errno: errno)
            }
            guard listen(fd, 16) == 0 else { throw LocalSocketError.system("listen", errno: errno) }
            guard pipe(&pipeFDs) == 0 else { throw LocalSocketError.system("pipe", errno: errno) }
            inode = info.st_ino
        } catch let error as LocalSocketError {
            close(fd)
            unlink(path)
            throw error
        } catch {
            preconditionFailure("only socket errors are thrown here: \(error)")
        }
        self.path = path
        listener = fd
        wakeRead = pipeFDs[0]
        wakeWrite = pipeFDs[1]
        let thread = Thread { [self] in
            run(
                allowedUID: allowedUID, requestCap: requestCap, timeoutSeconds: timeoutSeconds,
                problem: problem, handler: handler)
        }
        thread.name = "LocalSocketServer"
        thread.start()
    }

    /// Stops accepting, removes the socket file and returns once the thread has finished.
    /// Replies already handed out can still be sent.
    public func stop() {
        var byte: UInt8 = 0
        _ = write(wakeWrite, &byte, 1)
        stopped.wait()
    }

    private func run(
        allowedUID: uid_t, requestCap: Int, timeoutSeconds: Double,
        problem: @Sendable (LocalSocketError) -> Void, handler: Handler
    ) {
        defer {
            var info = stat()
            if lstat(path, &info) == 0, info.st_ino == inode { unlink(path) }
            close(listener)
            close(wakeRead)
            close(wakeWrite)
            stopped.signal()
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
            if entries[1].revents != 0 { return }
            guard entries[0].revents != 0 else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else {
                if errno != EINTR, errno != ECONNABORTED {
                    problem(.system("accept", errno: errno))
                }
                continue
            }
            do {
                try prepareConnection(client)
                let uid = try peerUID(client)
                guard uid == allowedUID else { throw LocalSocketError.otherUser(uid) }
                let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutSeconds * 1e9)
                let request = try LocalSocketFrame.read(client, cap: requestCap, deadline: deadline)
                handler(request, LocalSocketReply(fd: client, timeoutSeconds: timeoutSeconds))
            } catch let error as LocalSocketError {
                close(client)
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
public final class LocalSocketReply: @unchecked Sendable {
    private let fd: Int32
    private let timeoutSeconds: Double
    private let lock = NSLock()
    /// Guarded by `lock`.
    private var isSent = false

    init(fd: Int32, timeoutSeconds: Double) {
        self.fd = fd
        self.timeoutSeconds = timeoutSeconds
    }

    deinit {
        if !isSent { close(fd) }
    }

    public func send(_ data: Data) throws(LocalSocketError) {
        let first = lock.withLock {
            defer { isSent = true }
            return !isSent
        }
        precondition(first, "a reply is sent once")
        defer { close(fd) }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutSeconds * 1e9)
        try LocalSocketFrame.write(fd, data, deadline: deadline)
    }
}
