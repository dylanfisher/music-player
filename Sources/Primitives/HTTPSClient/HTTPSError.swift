import Foundation

/// Why an HTTPS request failed. No case holds a URL, a header or a body, so the text can go
/// to a log or an alert whatever the request carried.
public enum HTTPSError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The URL isn't https on port 443 to an allowed host, or has a user or password; nothing
    /// was sent.
    case refusedAddress
    /// No network, or the host can't be found or reached.
    case offline
    case timedOut
    /// The body passed the cap; the rest wasn't read.
    case tooLarge(cap: Int)
    /// The task waiting on it was cancelled.
    case cancelled
    /// TLS failed: the handshake, or a certificate the system doesn't trust, by its `URLError`
    /// code.
    case insecure(code: Int)
    /// Any other failure, by its `URLError` code.
    case failed(code: Int)

    public var description: String {
        switch self {
        case .refusedAddress: "the address isn't one the app may connect to"
        case .offline: "there is no connection to the server"
        case .timedOut: "the server didn't answer in time"
        case .tooLarge(let cap): "the body is over the \(cap)-byte cap"
        case .cancelled: "the request was cancelled"
        case .insecure(let code): "the secure connection failed (URL error \(code))"
        case .failed(let code): "the connection failed (URL error \(code))"
        }
    }
}
