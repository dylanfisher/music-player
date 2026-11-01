import Darwin
import Foundation

/// A message on the socket: its length as 4 bytes, big-endian, then its bytes. Each read and
/// write finishes by `deadline`, in `DispatchTime` nanoseconds, so a peer that sends slowly or
/// stops reading can't hold the other end.
enum LocalSocketFrame {
    static let headerBytes = 4

    static func read(_ fd: Int32, cap: Int, deadline: UInt64) throws(LocalSocketError) -> Data {
        let header = try readFully(fd, count: headerBytes, deadline: deadline)
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        // Refused before reading, so a declared size never becomes an allocation.
        guard length <= cap else { throw .tooLarge(bytes: length, cap: cap) }
        return try readFully(fd, count: length, deadline: deadline)
    }

    static func write(_ fd: Int32, _ data: Data, deadline: UInt64) throws(LocalSocketError) {
        let length = UInt32(data.count)
        var bytes = Data(
            (0..<headerBytes).reversed().map { UInt8(truncatingIfNeeded: length >> ($0 * 8)) })
        bytes.append(data)
        var sent = 0
        while sent < bytes.count {
            try wait(fd, for: Int16(POLLOUT), deadline: deadline)
            let count = bytes.withUnsafeBytes {
                Darwin.write(fd, $0.baseAddress! + sent, $0.count - sent)
            }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw .system("write", errno: errno)
            }
            sent += count
        }
    }

    private static func readFully(_ fd: Int32, count: Int, deadline: UInt64)
        throws(LocalSocketError)
        -> Data
    {
        var data = Data(count: count)
        var got = 0
        while got < count {
            try wait(fd, for: Int16(POLLIN), deadline: deadline)
            let read = data.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress! + got, count - got)
            }
            if read == 0 { throw .closed }
            if read < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw .system("read", errno: errno)
            }
            got += read
        }
        return data
    }

    /// Returns once `fd` is ready for `events`, or throws at the deadline.
    private static func wait(_ fd: Int32, for events: Int16, deadline: UInt64)
        throws(LocalSocketError)
    {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw .timedOut }
            var entry = pollfd(fd: fd, events: events, revents: 0)
            let waitMs = Int32(min((deadline - now + 999_999) / 1_000_000, UInt64(Int32.max)))
            let ready = poll(&entry, 1, waitMs)
            if ready > 0 { return }
            if ready < 0, errno != EINTR { throw .system("poll", errno: errno) }
        }
    }
}

/// Sets the options every connected socket gets: no SIGPIPE when the peer has gone, and
/// non-blocking, so a read or write never outlasts its deadline.
func prepareConnection(_ fd: Int32) throws(LocalSocketError) {
    var on: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0
    else { throw .system("setsockopt", errno: errno) }
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw .system("fcntl", errno: errno)
    }
}

/// A new Unix-domain stream socket.
func unixSocket() throws(LocalSocketError) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw .system("socket", errno: errno) }
    return fd
}

/// The user at the other end of a connected socket.
func peerUID(_ fd: Int32) throws(LocalSocketError) -> uid_t {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0 else { throw .system("getpeereid", errno: errno) }
    return uid
}

/// `path` as a socket address, or nil when it's too long for one.
func socketAddress(_ path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    let bytes = Array(path.utf8)
    // One byte stays for the NUL.
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return address
}

/// Runs `call` with `address` as the `sockaddr` the socket calls take.
func withSocketAddress<T>(_ address: sockaddr_un, _ call: (UnsafePointer<sockaddr>, socklen_t) -> T)
    -> T
{
    var address = address
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            call($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}
