import Darwin

/// Why a socket couldn't be set up, or a message couldn't be sent or read.
public enum LocalSocketError: Error, Equatable, CustomStringConvertible {
    /// Longer than `sockaddr_un` holds.
    case pathTooLong(String)
    /// The socket's folder is a link, not a folder, someone else's, or open to other users.
    case unsafeFolder(String, reason: String)
    /// A server already answers at the path.
    case inUse(String)
    /// Something other than this user's socket is at the path.
    case notASocket(String)
    /// Nothing answers at the path.
    case notListening(String)
    /// The other end runs as another user.
    case otherUser(uid_t)
    /// A message declared longer than the cap.
    case tooLarge(bytes: Int, cap: Int)
    case timedOut
    /// This many replies are already outstanding.
    case busy(Int)
    /// The other end closed before a whole message.
    case closed
    case system(String, errno: Int32)

    public var description: String {
        switch self {
        case .pathTooLong(let path): "\(path) is too long for a socket"
        case .unsafeFolder(let path, let reason): "\(path) \(reason)"
        case .inUse(let path): "another process already answers at \(path)"
        case .notASocket(let path): "\(path) isn't this user's socket"
        case .notListening(let path): "nothing answers at \(path)"
        case .otherUser(let uid): "the other end runs as user \(uid), not this user"
        case .tooLarge(let bytes, let cap):
            "a message of \(bytes) bytes is over the \(cap)-byte cap"
        case .timedOut: "the other end took too long"
        case .busy(let count): "\(count) replies are already waiting to be sent"
        case .closed: "the other end closed before a whole message"
        case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
        }
    }
}
