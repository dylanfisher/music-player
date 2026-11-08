import HTTPSClient

/// Why a Discogs API request failed (ADR 0138). No case holds the token, a header or a URL's
/// query, so the text can go to a log or an alert.
public enum DiscogsAPIError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A search, which Discogs answers only with a token, was asked for without one; nothing
    /// was sent.
    case tokenRequired
    /// 401 or 403.
    case unauthorized
    /// 404: no such release or master.
    case notFound
    /// A third 429 in a row.
    case rateLimited
    /// Any other status but 200.
    case status(Int)
    case offline
    case timedOut
    case tooLarge
    /// A reply that isn't what the API documents, or that passes a limit.
    case malformed(String)
    /// A URL the client may not connect to.
    case refusedAddress
    case cancelled

    public var description: String {
        switch self {
        case .tokenRequired: "searching Discogs needs a Discogs token in config.json"
        case .unauthorized: "the Discogs token was refused"
        case .notFound: "Discogs has no such release"
        case .rateLimited: "Discogs kept refusing requests for its rate limit"
        case .status(let code): "Discogs answered with status \(code)"
        case .offline: "there is no connection to Discogs"
        case .timedOut: "Discogs didn't answer in time"
        case .tooLarge: "Discogs's reply was larger than the app accepts"
        case .malformed(let why): "Discogs's reply wasn't usable: \(why)"
        case .refusedAddress: HTTPSError.refusedAddress.description
        case .cancelled: HTTPSError.cancelled.description
        }
    }

    /// Whether the run stops: the network, the token or the rate limit fails every album
    /// alike, so none is left as No Candidate because of it. A release that's missing or
    /// unusable is left out of its album's candidates alone.
    var stopsRun: Bool {
        switch self {
        case .notFound, .malformed, .tooLarge: false
        default: true
        }
    }

    init(_ error: HTTPSError) {
        self =
            switch error {
            case .refusedAddress: .refusedAddress
            case .offline: .offline
            case .timedOut: .timedOut
            case .tooLarge: .tooLarge
            case .cancelled: .cancelled
            case .failed: .offline
            }
    }
}
