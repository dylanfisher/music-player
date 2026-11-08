import Foundation
import HTTPSClient
import Log
import Settings

private let logger = moduleLogger()

/// Sends one GET: the URL, the headers, the body's cap in bytes and the timeout in seconds.
/// The app's is `DiscogsAPI.internet()`; tests answer from fixtures.
public typealias HTTPSTransport =
    @Sendable (URL, [String: String], Int, Double) async throws(HTTPSError) -> HTTPSResponse

/// The Discogs API: releases and masters by id, through the cache, and release searches
/// (ADR 0138). Requests go one at a time, paced by the rate-limit headers; a 429 waits as
/// Discogs says and is tried again twice. The token goes only into the `Authorization` header
/// of a request to `host`.
public actor DiscogsAPI {
    static let host = "api.discogs.com"
    /// Where Discogs serves images.
    static let imageHost = "i.discogs.com"
    static let baseURL = URL(string: "https://\(host)")!
    /// How long a cached release or master is used before it's fetched again.
    static let cacheDays = 30.0
    static let jsonCap = 4 * 1024 * 1024
    static let timeoutSeconds = 20.0
    /// Results a search asks for; only the first page is read.
    static let searchResults = 25
    /// Times a request refused with 429 is tried again before the run stops.
    static let rateLimitRetries = 2
    /// The longest a 429's `Retry-After` is waited for.
    static let longestRetrySeconds = 300.0
    /// Waits at least this long are reported to `waiting`; the usual gap of a second or two
    /// isn't.
    static let reportedWaitSeconds = 3.0

    /// What Discogs requires of every client: a name and version.
    public static func userAgent(version: String) -> String { "MusicPlayer/\(version)" }

    /// The app's transport: `HTTPSClient`, to the API and image hosts only.
    public static func internet() -> HTTPSTransport {
        let client = HTTPSClient(allowedHosts: [host, imageHost])
        return { url, headers, cap, timeout throws(HTTPSError) in
            try await client.get(url, headers: headers, cap: cap, timeoutSeconds: timeout)
        }
    }

    private let token: DiscogsToken?
    private let userAgent: String
    private let transport: HTTPSTransport
    private let cache: DiscogsCache
    private let now: @Sendable () -> Double
    private let uptime: @Sendable () -> Double
    private let sleep: @Sendable (Double) async throws -> Void
    private var limiter: RateLimiter
    /// Hears the seconds a long wait will take, then nil when it's over.
    private var waiting: @Sendable (Int?) -> Void = { _ in }
    private var busy = false
    private var queued: [CheckedContinuation<Void, Never>] = []

    /// `now` is the wall clock, which dates cache entries; `uptime` a clock that only goes
    /// forward, which paces requests, so setting the Mac's clock back can't stall a run;
    /// `sleep` waits. Tests replace all three so they don't wait.
    public init(
        token: DiscogsToken?, userAgent: String, transport: @escaping HTTPSTransport,
        cache: DiscogsCache,
        now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
        uptime: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping @Sendable (Double) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        }
    ) {
        self.token = token
        self.userAgent = userAgent
        self.transport = transport
        self.cache = cache
        self.now = now
        self.uptime = uptime
        self.sleep = sleep
        limiter = RateLimiter(hasToken: token != nil)
    }

    /// Whether there's a token, without which nothing searches.
    public nonisolated var hasToken: Bool { token != nil }

    func setWaiting(_ waiting: @escaping @Sendable (Int?) -> Void) {
        self.waiting = waiting
    }

    // MARK: Calls

    /// The release `id`, from the cache when it holds a readable entry under `cacheDays` old.
    public func release(id: Int) async throws(DiscogsAPIError) -> FetchedRelease {
        if let cached = await cachedRelease(id: id, maximumAgeDays: Self.cacheDays) {
            return cached
        }
        let body = try await get(Self.baseURL.appendingPathComponent("releases/\(id)")).body
        let fetched: FetchedRelease
        do {
            fetched = try JSONDecoder().decode(ApiRelease.self, from: Data(body))
                .fetched(requested: id, imageHost: Self.imageHost)
        } catch let error as DiscogsAPIError {
            throw error
        } catch {
            throw .malformed(Self.decodeProblem(error))
        }
        await store(.release, id, CachedRelease(fetched))
        return fetched
    }

    /// The release `id` as the cache holds it, at any age, with no request: for the sheets that
    /// list releases a run already fetched. Nil when the cache has no readable entry.
    func cachedRelease(id: Int) async -> FetchedRelease? {
        await cachedRelease(id: id, maximumAgeDays: .infinity)
    }

    private func cachedRelease(id: Int, maximumAgeDays: Double) async -> FetchedRelease? {
        guard let json = await cached(.release, id, maximumAgeDays: maximumAgeDays),
            let entry = try? JSONDecoder().decode(CachedRelease.self, from: Data(json.utf8)),
            entry.id == id
        else { return nil }
        return entry.fetched
    }

    /// The main release of the master `id`, through the cache as a release is.
    func mainRelease(master id: Int) async throws(DiscogsAPIError) -> Int? {
        if let json = await cached(.master, id),
            let entry = try? JSONDecoder().decode(CachedMaster.self, from: Data(json.utf8))
        {
            return entry.mainReleaseID
        }
        let body = try await get(Self.baseURL.appendingPathComponent("masters/\(id)")).body
        let master: ApiMaster
        do {
            master = try JSONDecoder().decode(ApiMaster.self, from: Data(body))
        } catch {
            throw .malformed(Self.decodeProblem(error))
        }
        guard master.id == id else { throw .malformed("master \(id) came back as \(master.id)") }
        let mainReleaseID = master.mainRelease.flatMap { $0 > 0 ? $0 : nil }
        await store(.master, id, CachedMaster(mainReleaseID: mainReleaseID))
        return mainReleaseID
    }

    /// The releases with `barcode`, best first.
    func search(barcode: String) async throws(DiscogsAPIError) -> [Int] {
        try await search(["barcode": barcode])
    }

    /// The releases on `label` with `catalogNumber`, best first.
    func search(catalogNumber: String, label: String) async throws(DiscogsAPIError) -> [Int] {
        try await search(["label": label, "catno": catalogNumber])
    }

    /// The releases by `artist` titled `title`, best first.
    func search(artist: String, title: String) async throws(DiscogsAPIError) -> [Int] {
        try await search(["artist": artist, "release_title": title])
    }

    /// The release ids a `/database/search` of releases with `fields` finds on its first page.
    /// Throws `.tokenRequired`, sending nothing, without a token.
    private func search(_ fields: [String: String]) async throws(DiscogsAPIError) -> [Int] {
        guard token != nil else { throw .tokenRequired }
        var parts = URLComponents(
            url: Self.baseURL.appendingPathComponent("database/search"),
            resolvingAgainstBaseURL: false)!
        let items =
            [("type", "release")] + fields.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            + [("per_page", String(Self.searchResults)), ("page", "1")]
        parts.percentEncodedQuery = items.map { "\(queryEncoded($0))=\(queryEncoded($1))" }
            .joined(separator: "&")
        let body = try await get(parts.url!).body
        let results: ApiSearch
        do {
            results = try JSONDecoder().decode(ApiSearch.self, from: Data(body))
        } catch {
            throw .malformed(Self.decodeProblem(error))
        }
        var seen: Set<Int> = []
        return results.results.prefix(Self.searchResults)
            .filter { ($0.type ?? "release") == "release" && $0.id > 0 }
            .map(\.id).filter { seen.insert($0).inserted }
    }

    /// The image at `url`, which must be https on `imageHost`, at most `Cover.byteCap` bytes. It
    /// is paced as the API's requests are and carries no token.
    func image(at url: URL) async throws(DiscogsAPIError) -> [UInt8] {
        guard HTTPSClient.allows(url, hosts: [Self.imageHost]) else { throw .refusedAddress }
        return try await get(url, cap: Cover.byteCap).body
    }

    // MARK: Requests

    /// GETs `url` once its turn and the rate limit allow, with the user agent and, to `host`
    /// only, the token. A 200 is returned; any other status throws.
    func get(_ url: URL, cap: Int = jsonCap) async throws(DiscogsAPIError) -> HTTPSResponse {
        await takeTurn()
        defer { endTurn() }
        var refusals = 0
        while true {
            try await pause(limiter.wait(at: uptime()))
            var headers = ["User-Agent": userAgent]
            if let authorization = authorization(for: url) {
                headers["Authorization"] = authorization
            }
            limiter.started(at: uptime())
            let response: HTTPSResponse
            do {
                response = try await transport(url, headers, cap, Self.timeoutSeconds)
            } catch {
                throw DiscogsAPIError(error)
            }
            limiter.heard(response)
            switch response.status {
            case 200: return response
            case 429:
                refusals += 1
                guard refusals <= Self.rateLimitRetries else { throw .rateLimited }
                // "nan" and "inf" read as numbers, and would skip the wait or make it endless.
                let after =
                    response.header("Retry-After").flatMap { Double($0) }.flatMap {
                        $0.isFinite ? $0 : nil
                    } ?? 60
                try await pause(min(max(after, 1), Self.longestRetrySeconds))
            case 401, 403: throw .unauthorized
            case 404: throw .notFound
            default: throw .status(response.status)
            }
        }
    }

    /// The one place the token becomes a header: for a request to `host`, and only with a
    /// token.
    private func authorization(for url: URL) -> String? {
        guard let token, url.host?.lowercased() == Self.host else { return nil }
        return "Discogs token=\(token.secret)"
    }

    /// Waits `seconds`, telling `waiting` when it's long; cancelling the task stops it.
    private func pause(_ seconds: Double) async throws(DiscogsAPIError) {
        guard seconds > 0 else { return }
        let reported = seconds >= Self.reportedWaitSeconds
        if reported { waiting(Int(seconds.rounded(.up))) }
        defer { if reported { waiting(nil) } }
        do {
            try await sleep(seconds)
        } catch {
            throw .cancelled
        }
        if Task.isCancelled { throw .cancelled }
    }

    /// Waits until no other request is under way.
    private func takeTurn() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { queued.append($0) }
    }

    private func endTurn() {
        if queued.isEmpty {
            busy = false
        } else {
            queued.removeFirst().resume()
        }
    }

    // MARK: Cache

    /// An entry under `maximumAgeDays` old. One dated in the future, after the clock was set
    /// back, counts as expired.
    private func cached(
        _ kind: DiscogsCache.Kind, _ id: Int, maximumAgeDays: Double = cacheDays
    ) async -> String? {
        do {
            guard let entry = try await cache.read(kind, id),
                (0..<maximumAgeDays * 86_400).contains(now() - entry.fetchedAt)
            else { return nil }
            return entry.json
        } catch {
            logger.error("couldn't read the Discogs cache for \(kind.rawValue) \(id): \(error)")
            return nil
        }
    }

    private func store(_ kind: DiscogsCache.Kind, _ id: Int, _ value: some Encodable) async {
        do {
            let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            try await cache.store(kind, id, (now(), json))
        } catch {
            logger.error("couldn't keep \(kind.rawValue) \(id) in the Discogs cache: \(error)")
        }
    }

    /// Where a decode failed, without the text it read.
    private static func decodeProblem(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return "it isn't JSON" }
        switch error {
        case .keyNotFound(let key, let context):
            return path(context.codingPath + [key]) + " is missing"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return path(context.codingPath) + " has the wrong type"
        case .dataCorrupted: return "it isn't JSON"
        @unknown default: return "it doesn't decode"
        }
    }

    private static func path(_ keys: [any CodingKey]) -> String {
        let text = keys.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        return text.isEmpty ? "the reply" : String(text.drop { $0 == "." })
    }
}

/// `text` percent-encoded for a query value: everything but unreserved characters, so a `+`
/// or an `&` in a catalog number isn't read as a space or a new field.
private func queryEncoded(_ text: String) -> String {
    text.addingPercentEncoding(withAllowedCharacters: unreserved)!
}

private let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

/// A master as `/masters/{id}` returns it: only what the tie-break needs.
struct ApiMaster: Decodable {
    var id: Int
    var mainRelease: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case mainRelease = "main_release"
    }
}

/// A `/database/search` reply: its results in rank order.
struct ApiSearch: Decodable {
    struct Result: Decodable {
        var id: Int
        var type: String?
    }

    var results: [Result]
}
