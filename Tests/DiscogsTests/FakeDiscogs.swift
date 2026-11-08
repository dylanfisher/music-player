import Foundation
import HTTPSClient

@testable import Discogs
@testable import Settings

/// Made up for these tests; no real token appears in a test (ADR 0137).
let fakeToken = DiscogsToken("fakeTOKENfor3tests0nly")

/// The text of a written API reply in `Fixtures/api`.
func apiFixture(_ name: String) -> [UInt8] {
    let url = Bundle.module.url(forResource: "Fixtures/api/\(name)", withExtension: "json")!
    return Array(try! Data(contentsOf: url))
}

/// What a callback heard, from any thread.
final class Recorded<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func add(_ value: Value) { lock.withLock { values.append(value) } }
    var all: [Value] { lock.withLock { values } }
}

/// Discogs as the tests have it: replies from the fixtures, or from `replies` by path first,
/// a clock that moves only when the API sleeps, and every request recorded. Nothing here
/// opens a socket (AGENTS.md).
final class FakeDiscogs: @unchecked Sendable {
    struct Request {
        var url: URL
        var headers: [String: String]
    }

    private let lock = NSLock()
    private var queued: [String: [Result<HTTPSResponse, HTTPSError>]] = [:]
    private var log: [Request] = []
    private var clock = 1_000_000.0
    private var slept: [Double] = []
    /// The cache, by kind and id.
    private var stored: [String: DiscogsCache.Entry] = [:]

    /// The release fixtures by id.
    static let releases = [
        1001: "release-simple", 1002: "release-multi-disc", 1003: "release-vinyl-sides",
        1004: "release-index-tracks", 1005: "release-anv-variations", 1006: "release-no-images",
    ]

    /// The next replies to the path, in order, before the fixtures answer it.
    func queue(_ path: String, _ replies: Result<HTTPSResponse, HTTPSError>...) {
        lock.withLock { queued[path, default: []] += replies }
    }

    func queue(_ path: String, status: Int, headers: [String: String] = [:], body: [UInt8] = []) {
        queue(path, .success(HTTPSResponse(status: status, headers: headers, body: body)))
    }

    var requests: [Request] { lock.withLock { log } }
    var sleeps: [Double] { lock.withLock { slept } }
    var now: Double { lock.withLock { clock } }

    func advance(_ seconds: Double) { lock.withLock { clock += seconds } }

    func cacheEntry(_ kind: DiscogsCache.Kind, _ id: Int) -> DiscogsCache.Entry? {
        lock.withLock { stored["\(kind.rawValue) \(id)"] }
    }

    func setCacheEntry(_ kind: DiscogsCache.Kind, _ id: Int, _ entry: DiscogsCache.Entry) {
        lock.withLock { stored["\(kind.rawValue) \(id)"] = entry }
    }

    var transport: HTTPSTransport {
        { [self] url, headers, _, _ throws(HTTPSError) in
            let reply = lock.withLock { () -> Result<HTTPSResponse, HTTPSError>? in
                log.append(Request(url: url, headers: headers))
                guard var replies = queued[url.path], !replies.isEmpty else { return nil }
                let first = replies.removeFirst()
                queued[url.path] = replies
                return first
            }
            if let reply { return try reply.get() }
            return answer(url)
        }
    }

    /// What Discogs would answer from the fixtures: a release or master by id, a search by
    /// what it searches, and 404 for anything else.
    private func answer(_ url: URL) -> HTTPSResponse {
        let headers = ["X-Discogs-Ratelimit": "60", "X-Discogs-Ratelimit-Remaining": "59"]
        let parts = url.pathComponents
        let ok = { (name: String) in
            HTTPSResponse(status: 200, headers: headers, body: apiFixture(name))
        }
        if parts.count == 3, parts[1] == "releases", let id = Int(parts[2]),
            let name = Self.releases[id]
        {
            return ok(name)
        }
        if url.path == "/masters/500" { return ok("master") }
        if url.path == "/database/search" {
            let query = url.query ?? ""
            if query.contains("barcode=") { return ok("search-barcode") }
            if query.contains("release_title=Stockholm") { return ok("search-title") }
            return ok("search-empty")
        }
        return HTTPSResponse(status: 404, headers: headers, body: Array(#"{"message": "x"}"#.utf8))
    }

    var cache: DiscogsCache {
        DiscogsCache(
            read: { [self] kind, id in cacheEntry(kind, id) },
            store: { [self] kind, id, entry in setCacheEntry(kind, id, entry) })
    }

    func api(token: DiscogsToken? = fakeToken) -> DiscogsAPI {
        DiscogsAPI(
            token: token, userAgent: DiscogsAPI.userAgent(version: "1.0"), transport: transport,
            cache: cache, now: { [self] in now },
            sleep: { [self] seconds in
                try Task.checkCancellation()
                lock.withLock {
                    slept.append(seconds)
                    clock += seconds
                }
            })
    }
}
