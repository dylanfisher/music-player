import Darwin

/// Why a search, a request or the server failed.
public enum LocalNetworkError: Error, Equatable, CustomStringConvertible {
    case system(String, errno: Int32)
    /// The other end refused the connection, or nothing answers there.
    case refused(String)
    /// The connection failed or closed early.
    case failed(String)
    case timedOut
    /// The task waiting on it was cancelled.
    case cancelled
    /// More bytes than the cap allows.
    case tooLarge(cap: Int)
    /// A reply that isn't the HTTP it should be.
    case malformed(String)
    /// A status other than 200, a redirect among them; redirects are never followed.
    case status(Int)
    /// A status other than 200 with its head and body as received, for a caller that keeps them.
    case statusReply(Int, raw: [UInt8])

    public var description: String {
        switch self {
        case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
        case .refused(let why): "the connection was refused: \(why)"
        case .failed(let why): "the connection failed: \(why)"
        case .timedOut: "no answer in time"
        case .cancelled: "it was cancelled"
        case .tooLarge(let cap): "the reply is over the \(cap)-byte cap"
        case .malformed(let why): "the reply isn't valid HTTP: \(why)"
        case .status(let code), .statusReply(let code, _): "the reply's status is \(code)"
        }
    }
}
