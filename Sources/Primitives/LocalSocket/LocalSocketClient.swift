import Darwin
import Foundation

/// Sends `request` to the server at `path` and returns its reply, refusing a server that runs
/// as any user but `serverUID`, and a reply over `replyCap` bytes. The exchange finishes within
/// `timeoutSeconds`.
public func localSocketExchange(
    path: String, request: Data, replyCap: Int, timeoutSeconds: Double,
    serverUID: uid_t = geteuid()
) throws(LocalSocketError) -> Data {
    guard let address = socketAddress(path) else { throw .pathTooLong(path) }
    let fd = try unixSocket()
    defer { close(fd) }
    // A Unix-domain connect finishes at once or fails, so it can block before the deadline
    // starts.
    if withSocketAddress(address, { connect(fd, $0, $1) }) != 0 {
        if errno == ENOENT || errno == ECONNREFUSED { throw .notListening(path) }
        throw .system("connect", errno: errno)
    }
    try prepareConnection(fd)
    let uid = try peerUID(fd)
    guard uid == serverUID else { throw .otherUser(uid) }
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutSeconds * 1e9)
    try LocalSocketFrame.write(fd, request, deadline: deadline)
    return try LocalSocketFrame.read(fd, cap: replyCap, deadline: deadline)
}
