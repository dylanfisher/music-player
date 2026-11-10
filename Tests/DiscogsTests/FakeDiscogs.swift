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

private func track(_ position: String, _ title: String, _ duration: String = "") -> String {
    "<track><position>\(position)</position><title>\(title)</title><duration>\(duration)</duration></track>"
}

private func heading(_ title: String) -> String { track("", title) }

private let persuader = "<artists><artist><id>1</id><name>Persuader</name></artist></artists>"

/// The dump's XML for each release fixture: the same release as the API writes it.
private let dumpReleaseRecords = [
    #"<release id="1001">\#(persuader)<title>Stockholm</title><labels><label name="Svek" catno="SK 032" id="5"/></labels><extraartists><artist><id>7</id><name>Jesper Dahlbäck</name><anv></anv><role>Producer</role><tracks></tracks></artist></extraartists><formats><format name="CD" qty="1" text=""><descriptions><description>Album</description></descriptions></format></formats><genres><genre>Electronic</genre></genres><styles><style>Techno</style><style>Minimal</style></styles><country>Sweden</country><released>1999-03-00</released><notes>Recorded in Stockholm.</notes><master_id is_main_release="false">500</master_id><data_quality>Correct</data_quality><tracklist>\#(track("1", "Östermalm", "4:45"))\#(track("2", "Gamla Stan", "6:10"))\#(track("3", "Kungsholmen", "5:00"))</tracklist><identifiers><identifier type="Barcode" value="7 350001 000123" description="Text"/><identifier type="Matrix / Runout" value="SK032 01"/></identifiers><companies><company><id>77</id><name>Svek Studios</name></company></companies></release>"#,
    #"<release id="1002">\#(persuader)<title>Stockholm</title><labels><label name="Svek" catno="SK 032CD" id="5"/><label name="Other" catno="none" id="6"/></labels><formats><format name="CD" qty="2" text="Digipak"><descriptions><description>Album</description><description>Remastered</description></descriptions></format></formats><genres><genre>Electronic</genre></genres><styles><style>Techno</style></styles><country>Europe</country><released>2009</released><master_id is_main_release="false">500</master_id><tracklist>\#(heading("Disc One"))\#(track("1-1", "Östermalm", "4:45"))\#(track("1-2", "Gamla Stan", "6:10"))\#(heading("Disc Two"))\#(track("2-1", "Kungsholmen", "5:00"))</tracklist></release>"#,
    #"<release id="1003">\#(persuader)<title>Stockholm</title><labels><label name="Svek" catno="SK 032" id="5"/></labels><formats><format name="Vinyl" qty="2" text=""><descriptions><description>12&quot;</description><description>33 ⅓ RPM</description><description>Album</description></descriptions></format></formats><genres><genre>Electronic</genre></genres><styles><style>Techno</style></styles><country>Sweden</country><released>1999</released><master_id is_main_release="false">500</master_id><tracklist>\#(heading("Side A"))\#(track("A1", "Östermalm", "4:45"))\#(track("A2", "Gamla Stan", "6:10"))\#(heading("Side B"))\#(track("B1", "Kungsholmen", "5:00"))\#(track("B2", "Södermalm"))</tracklist><identifiers><identifier type="Barcode" value="7350001000130"/></identifiers></release>"#,
    #"<release id="1004">\#(persuader)<title>Suites</title><labels><label name="Svek" catno="SK 040" id="5"/></labels><formats><format name="File" qty="1" text=""><descriptions><description>FLAC</description><description>Album</description></descriptions></format></formats><genres><genre>Electronic</genre></genres><country>Sweden</country><released>2001-05-14</released><tracklist>\#(track("1", "Östermalm", "4:45"))<track><position></position><title>Suite</title><duration></duration><sub_tracks>\#(track("2a", "Gamla Stan", "6:10"))\#(track("2b", "Kungsholmen", "5:00"))</sub_tracks></track></tracklist></release>"#,
    #"<release id="1005"><artists><artist><id>21</id><name>Soleil (2)</name><anv>Soleil</anv><join>&amp;</join></artist><artist><id>22</id><name>Lune</name><anv></anv><join></join></artist></artists><title>  Duos  </title><labels><label name="Svek" catno="SK 050" id="5"/></labels><extraartists><artist><id>7</id><name>Jesper Dahlbäck</name><anv>J. Dahlbäck</anv><role>Written-By [All Tracks By]</role><tracks>1, 2</tracks></artist><artist><name>Unlinked Engineer</name><role>Mastered By</role></artist></extraartists><formats><format name="CD" qty="1"><descriptions><description>Album</description></descriptions></format></formats><genres><genre>Electronic</genre></genres><styles><style>House</style></styles><country>Sweden</country><released>2003</released><master_id is_main_release="false">0</master_id><tracklist><track><position>1</position><title>Matin</title><duration>3:30</duration><artists><artist><id>21</id><name>Soleil (2)</name><anv>Sol</anv><join>Feat.</join></artist><artist><id>23</id><name>Nuage</name></artist></artists><extraartists><artist><id>22</id><name>Lune</name><anv>L.</anv><role>Remix</role></artist></extraartists></track>\#(track("2", "Soir", "1:02:03"))</tracklist></release>"#,
    #"<release id="1006">\#(persuader)<title>Stockholm</title><labels><label name="Svek" catno="SK 032" id="5"/></labels><formats><format name="CD" qty="1"/></formats><genres><genre>Electronic</genre></genres><released>1999</released><master_id is_main_release="false">500</master_id><tracklist>\#(track("1", "Östermalm", "4:45"))\#(track("2", "Gamla Stan", "6:10"))\#(track("3", "Kungsholmen", "5:00"))</tracklist></release>"#,
]

/// The release fixtures as the dump writes them, a record a line.
let apiDumpReleases = dumpReleaseRecords.joined(separator: "\n") + "\n"

/// The master fixture as the dump writes it.
let apiDumpMasters =
    #"<master id="500"><main_release>1001</main_release>\#(persuader)<title>Stockholm</title></master>"#
    + "\n"

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

    func removeCacheEntries(_ kind: DiscogsCache.Kind, _ ids: [Int]) {
        lock.withLock { for id in ids { stored["\(kind.rawValue) \(id)"] = nil } }
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

    /// The covers this fake's APIs keep, in a temp folder of their own.
    let covers = CoverStore(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent(
            "discogs-covers-\(UUID().uuidString)", isDirectory: true))

    var cache: DiscogsCache {
        DiscogsCache(
            read: { [self] kind, id in cacheEntry(kind, id) },
            store: { [self] kind, id, entry in setCacheEntry(kind, id, entry) },
            remove: { [self] kind, ids in removeCacheEntries(kind, ids) })
    }

    func api(token: DiscogsToken? = fakeToken) -> DiscogsAPI {
        DiscogsAPI(
            token: token, userAgent: DiscogsAPI.userAgent(version: "1.0"), transport: transport,
            cache: cache, covers: covers, now: { [self] in now }, uptime: { [self] in now },
            sleep: { [self] seconds in
                try Task.checkCancellation()
                lock.withLock {
                    slept.append(seconds)
                    clock += seconds
                }
            })
    }
}
