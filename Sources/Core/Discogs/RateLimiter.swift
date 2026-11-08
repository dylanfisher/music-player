import HTTPSClient

/// How long the next Discogs request waits (ADR 0138). Discogs allows a number of requests in
/// a moving minute, and says in each reply how many and how many are left: requests start
/// `windowSeconds / limit` apart, and when none are left the next waits a whole window.
struct RateLimiter: Sendable {
    static let windowSeconds = 60.0
    /// Discogs's limits with and without a token, until a reply says otherwise.
    static let limitWithToken = 60
    static let limitWithoutToken = 25
    /// The most a reply's limit is believed, so a hostile one can't make the gap vanish.
    static let largestLimit = 240

    private(set) var limit: Int
    private(set) var remaining: Int?
    private var lastStart: Double?

    init(hasToken: Bool) {
        limit = hasToken ? Self.limitWithToken : Self.limitWithoutToken
    }

    /// Seconds from `now` until the next request may start.
    func wait(at now: Double) -> Double {
        guard let lastStart else { return 0 }
        let gap = remaining == 0 ? Self.windowSeconds : Self.windowSeconds / Double(limit)
        return max(0, lastStart + gap - now)
    }

    mutating func started(at now: Double) { lastStart = now }

    /// Takes the limit and what's left from a reply's `X-Discogs-Ratelimit` headers.
    mutating func heard(_ response: HTTPSResponse) {
        if let text = response.header("X-Discogs-Ratelimit"), let value = Int(text), value > 0 {
            limit = min(value, Self.largestLimit)
        }
        if let text = response.header("X-Discogs-Ratelimit-Remaining"), let value = Int(text),
            value >= 0
        {
            remaining = value
        }
    }
}
