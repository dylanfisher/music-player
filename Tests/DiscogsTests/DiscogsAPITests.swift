import Foundation
import HTTPSClient
import Testing

@testable import Discogs

private func track(_ position: String, _ title: String, _ duration: String = "") -> String {
    "<track><position>\(position)</position><title>\(title)</title><duration>\(duration)</duration></track>"
}

private func heading(_ title: String) -> String { track("", title) }

private let persuader = "<artists><artist><id>1</id><name>Persuader</name></artist></artists>"

/// The dump's XML for each release fixture: the same release as the API writes it.
private let dumpReleases = [
    #"<release id="1001">\#(persuader)<title>Stockholm</title><labels><label name="Svek" catno="SK 032" id="5"/></labels><extraartists><artist><id>7</id><name>Jesper Dahlbäck</name><anv></anv><role>Producer</role><tracks></tracks></artist></extraartists><formats><format name="CD" qty="1" text=""><descriptions><description>Album</description></descriptions></format></formats><genres><genre>Electronic</genre></genres><styles><style>Techno</style><style>Minimal</style></styles><country>Sweden</country><released>1999-03-00</released><notes>Recorded in Stockholm.</notes><master_id is_main_release="false">500</master_id><data_quality>Correct</data_quality><tracklist>\#(track("1", "Östermalm", "4:45"))\#(track("2", "Gamla Stan", "6:10"))\#(track("3", "Kungsholmen", "5:00"))</tracklist><identifiers><identifier type="Barcode" value="7 350001 000123" description="Text"/><identifier type="Matrix / Runout" value="SK032 01"/></identifiers><companies><company><id>77</id><name>Svek Studios</name></company></companies></release>"#,
    #"<release id="1002">\#(persuader)<title>Stockholm</title><labels><label name="Svek" catno="SK 032CD" id="5"/><label name="Other" catno="none" id="6"/></labels><formats><format name="CD" qty="2" text="Digipak"><descriptions><description>Album</description><description>Remastered</description></descriptions></format></formats><genres><genre>Electronic</genre></genres><styles><style>Techno</style></styles><country>Europe</country><released>2009</released><master_id is_main_release="false">500</master_id><tracklist>\#(heading("Disc One"))\#(track("1-1", "Östermalm", "4:45"))\#(track("1-2", "Gamla Stan", "6:10"))\#(heading("Disc Two"))\#(track("2-1", "Kungsholmen", "5:00"))</tracklist></release>"#,
    #"<release id="1003">\#(persuader)<title>Stockholm</title><labels><label name="Svek" catno="SK 032" id="5"/></labels><formats><format name="Vinyl" qty="2" text=""><descriptions><description>12&quot;</description><description>33 ⅓ RPM</description><description>Album</description></descriptions></format></formats><genres><genre>Electronic</genre></genres><styles><style>Techno</style></styles><country>Sweden</country><released>1999</released><master_id is_main_release="false">500</master_id><tracklist>\#(heading("Side A"))\#(track("A1", "Östermalm", "4:45"))\#(track("A2", "Gamla Stan", "6:10"))\#(heading("Side B"))\#(track("B1", "Kungsholmen", "5:00"))\#(track("B2", "Södermalm"))</tracklist><identifiers><identifier type="Barcode" value="7350001000130"/></identifiers></release>"#,
    #"<release id="1004">\#(persuader)<title>Suites</title><labels><label name="Svek" catno="SK 040" id="5"/></labels><formats><format name="File" qty="1" text=""><descriptions><description>FLAC</description><description>Album</description></descriptions></format></formats><genres><genre>Electronic</genre></genres><country>Sweden</country><released>2001-05-14</released><tracklist>\#(track("1", "Östermalm", "4:45"))<track><position></position><title>Suite</title><duration></duration><sub_tracks>\#(track("2a", "Gamla Stan", "6:10"))\#(track("2b", "Kungsholmen", "5:00"))</sub_tracks></track></tracklist></release>"#,
    #"<release id="1005"><artists><artist><id>21</id><name>Soleil (2)</name><anv>Soleil</anv><join>&amp;</join></artist><artist><id>22</id><name>Lune</name><anv></anv><join></join></artist></artists><title>  Duos  </title><labels><label name="Svek" catno="SK 050" id="5"/></labels><extraartists><artist><id>7</id><name>Jesper Dahlbäck</name><anv>J. Dahlbäck</anv><role>Written-By [All Tracks By]</role><tracks>1, 2</tracks></artist><artist><name>Unlinked Engineer</name><role>Mastered By</role></artist></extraartists><formats><format name="CD" qty="1"><descriptions><description>Album</description></descriptions></format></formats><genres><genre>Electronic</genre></genres><styles><style>House</style></styles><country>Sweden</country><released>2003</released><master_id is_main_release="false">0</master_id><tracklist><track><position>1</position><title>Matin</title><duration>3:30</duration><artists><artist><id>21</id><name>Soleil (2)</name><anv>Sol</anv><join>Feat.</join></artist><artist><id>23</id><name>Nuage</name></artist></artists><extraartists><artist><id>22</id><name>Lune</name><anv>L.</anv><role>Remix</role></artist></extraartists></track>\#(track("2", "Soir", "1:02:03"))</tracklist></release>"#,
    #"<release id="1006">\#(persuader)<title>Stockholm</title><labels><label name="Svek" catno="SK 032" id="5"/></labels><formats><format name="CD" qty="1"/></formats><genres><genre>Electronic</genre></genres><released>1999</released><master_id is_main_release="false">500</master_id><tracklist>\#(track("1", "Östermalm", "4:45"))\#(track("2", "Gamla Stan", "6:10"))\#(track("3", "Kungsholmen", "5:00"))</tracklist></release>"#,
]

@Test func eachReleaseFromTheAPIIsWhatTheCatalogHoldsForIt() async throws {
    let folder = try DumpFolder()
    try folder.write("20261101", releases: dumpReleases.joined(separator: "\n") + "\n")
    let catalog = try folder.importedCatalog()
    let api = FakeDiscogs().api()
    for id in FakeDiscogs.releases.keys.sorted() {
        let fetched = try await api.release(id: id).release
        let dumped = try #require(try catalog.release(id: id))
        // Field by field, so a difference names its field.
        #expect(fetched.masterID == dumped.masterID, "\(id)")
        #expect(fetched.isMainRelease == dumped.isMainRelease, "\(id)")
        #expect(fetched.title == dumped.title, "\(id)")
        #expect(fetched.artists == dumped.artists, "\(id)")
        #expect(fetched.labels == dumped.labels, "\(id)")
        #expect(fetched.formats == dumped.formats, "\(id)")
        #expect(fetched.country == dumped.country, "\(id)")
        #expect(fetched.released == dumped.released, "\(id)")
        #expect(fetched.genres == dumped.genres, "\(id)")
        #expect(fetched.styles == dumped.styles, "\(id)")
        #expect(fetched.barcodes == dumped.barcodes, "\(id)")
        #expect(fetched.credits == dumped.credits, "\(id)")
        #expect(fetched.tracks == dumped.tracks, "\(id)")
        #expect(fetched == dumped, "\(id)")
    }
}

@Test func thePrimaryImageIsTheOneOfTypePrimaryElseTheFirst() async throws {
    let api = FakeDiscogs().api()
    #expect(try await api.release(id: 1001).primaryImage?.lastPathComponent == "front-1001.jpg")
    #expect(try await api.release(id: 1004).primaryImage?.lastPathComponent == "only-1004.png")
    #expect(try await api.release(id: 1006).primaryImage == nil)
}

/// A release reply whose JSON is the simple fixture's with `change` made to it.
private func changedRelease(_ change: (inout [String: Any]) -> Void) -> [UInt8] {
    var object =
        try! JSONSerialization.jsonObject(with: Data(apiFixture("release-simple")))
        as! [String: Any]
    change(&object)
    return Array(try! JSONSerialization.data(withJSONObject: object))
}

@Test func anImageThatIsntHTTPSOnTheImageHostIsDropped() async throws {
    for uri in [
        "http://i.discogs.com/front.jpg", "https://evil.example/front.jpg",
        "https://user@i.discogs.com/front.jpg", "https://i.discogs.com:8443/front.jpg",
        "file:///etc/passwd",
    ] {
        let fake = FakeDiscogs()
        fake.queue(
            "/releases/1001", status: 200,
            body: changedRelease { $0["images"] = [["type": "primary", "uri": uri]] })
        let fetched = try await fake.api().release(id: 1001)
        #expect(fetched.primaryImage == nil, "\(uri)")
        #expect(fetched.release.title == "Stockholm")
    }
}

@Test func theTokenGoesOnlyToTheAPIHostInItsHeader() async throws {
    let fake = FakeDiscogs()
    let api = fake.api()
    _ = try await api.release(id: 1001)
    _ = try await api.search(barcode: "7 350001 000123")
    fake.queue("/front-1001.jpg", status: 200, body: [0xFF, 0xD8])
    _ = try await api.get(URL(string: "https://i.discogs.com/front-1001.jpg")!)
    let requests = fake.requests
    #expect(requests.count == 3)
    for request in requests {
        #expect(!request.url.absoluteString.contains(fakeToken.secret))
        #expect(
            request.headers.filter { $0.key != "Authorization" }.values.allSatisfy {
                !$0.contains(fakeToken.secret)
            })
        #expect(request.headers["User-Agent"] == "MusicPlayer/1.0")
    }
    #expect(requests[0].headers["Authorization"] == "Discogs token=\(fakeToken.secret)")
    #expect(requests[1].headers["Authorization"] == "Discogs token=\(fakeToken.secret)")
    #expect(requests[2].headers["Authorization"] == nil)
}

@Test func withoutATokenNoHeaderIsSentAndNothingSearches() async throws {
    let fake = FakeDiscogs()
    let api = fake.api(token: nil)
    #expect(!api.hasToken)
    #expect(try await api.release(id: 1006).release.title == "Stockholm")
    #expect(fake.requests.first?.headers["Authorization"] == nil)
    #expect(fake.requests.first?.headers["User-Agent"] == "MusicPlayer/1.0")
    await #expect(throws: DiscogsAPIError.tokenRequired) { try await api.search(barcode: "1") }
    await #expect(throws: DiscogsAPIError.tokenRequired) {
        try await api.search(catalogNumber: "SK 032", label: "Svek")
    }
    await #expect(throws: DiscogsAPIError.tokenRequired) {
        try await api.search(artist: "Persuader", title: "Stockholm")
    }
    #expect(fake.requests.count == 1)
}

@Test func aSearchGivesItsReleasesInRankOrderOnceEach() async throws {
    let fake = FakeDiscogs()
    let api = fake.api()
    #expect(try await api.search(barcode: "7 350001 000123") == [1001, 1003])
    #expect(try await api.search(artist: "Persuader", title: "Stockholm") == [1002, 1006])
    #expect(try await api.search(catalogNumber: "SK+032 & 1", label: "Svek") == [])
    let query = try #require(fake.requests.last?.url.query)
    // A "+" or "&" in a value is encoded, so Discogs doesn't read a space or a new field.
    #expect(query.contains("catno=SK%2B032%20%26%201"))
    #expect(query.contains("type=release"))
    #expect(query.contains("per_page=25"))
    #expect(query.contains("page=1"))
}

@Test func requestsAreSpacedByTheRateLimit() async throws {
    for (token, limit, gap) in [(fakeToken, "60", 1.0), (nil, "25", 2.4)] {
        let fake = FakeDiscogs()
        let api = fake.api(token: token)
        for id in [1001, 1002, 1003] {
            fake.queue(
                "/releases/\(id)", status: 200,
                headers: ["X-Discogs-Ratelimit": limit, "X-Discogs-Ratelimit-Remaining": "20"],
                body: apiFixture(FakeDiscogs.releases[id]!))
            _ = try await api.release(id: id)
        }
        #expect(fake.sleeps.count == 2, "\(limit)")
        #expect(fake.sleeps.allSatisfy { abs($0 - gap) < 1e-9 }, "\(fake.sleeps)")
    }
    // Without a reply yet, the limit is the one for having a token or not.
    #expect(RateLimiter(hasToken: true).limit == 60)
    #expect(RateLimiter(hasToken: false).limit == 25)
}

@Test func noneRemainingWaitsTheWholeWindow() async throws {
    let fake = FakeDiscogs()
    let api = fake.api()
    let waits = Recorded<Int?>()
    await api.setWaiting { waits.add($0) }
    fake.queue(
        "/releases/1001", status: 200,
        headers: ["X-Discogs-Ratelimit": "60", "X-Discogs-Ratelimit-Remaining": "0"],
        body: apiFixture("release-simple"))
    _ = try await api.release(id: 1001)
    _ = try await api.release(id: 1002)
    #expect(fake.sleeps == [60])
    #expect(waits.all == [60, nil])
}

@Test func a429WaitsAsToldAndATheThirdStopsTheRun() async throws {
    let fake = FakeDiscogs()
    let api = fake.api()
    fake.queue("/releases/1001", status: 429, headers: ["Retry-After": "40"])
    #expect(try await api.release(id: 1001).release.id == 1001)
    #expect(fake.sleeps.contains(40))
    let refused = HTTPSResponse(status: 429, headers: [:], body: [])
    fake.queue("/releases/1002", .success(refused), .success(refused), .success(refused))
    await #expect(throws: DiscogsAPIError.rateLimited) { try await api.release(id: 1002) }
    #expect(fake.sleeps.filter { $0 == 60 }.count == 2)
    #expect(DiscogsAPIError.rateLimited.stopsRun)
}

@Test func cancellingDuringAWaitStopsIt() async throws {
    let fake = FakeDiscogs()
    let api = DiscogsAPI(
        token: fakeToken, userAgent: "MusicPlayer/1.0", transport: fake.transport,
        cache: fake.cache, now: { fake.now },
        sleep: { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) })
    fake.queue("/releases/1001", status: 429, headers: ["Retry-After": "120"])
    let task = Task { () async -> DiscogsAPIError? in
        do throws(DiscogsAPIError) {
            _ = try await api.release(id: 1001)
            return nil
        } catch {
            return error
        }
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    task.cancel()
    #expect(await task.value == .cancelled)
    #expect(fake.requests.count == 1)
}

@Test func statusesAndNetworkFailuresMapToTheirErrors() async throws {
    let fake = FakeDiscogs()
    let api = fake.api()
    for (reply, error) in [
        (
            Result<HTTPSResponse, HTTPSError>.success(.init(status: 401, headers: [:], body: [])),
            DiscogsAPIError.unauthorized
        ),
        (.success(.init(status: 404, headers: [:], body: [])), .notFound),
        (.success(.init(status: 500, headers: [:], body: [])), .status(500)),
        (.success(.init(status: 302, headers: ["Location": "https://x"], body: [])), .status(302)),
        (.failure(.offline), .offline), (.failure(.timedOut), .timedOut),
        (.failure(.tooLarge(cap: 4)), .tooLarge), (.failure(.refusedAddress), .refusedAddress),
    ] {
        fake.queue("/releases/1001", reply)
        await #expect(throws: error) { try await api.release(id: 1001) }
    }
    #expect(DiscogsAPIError.unauthorized.stopsRun)
    #expect(DiscogsAPIError.offline.stopsRun)
    #expect(DiscogsAPIError.timedOut.stopsRun)
    #expect(!DiscogsAPIError.notFound.stopsRun)
}

@Test func aReleaseThatPassesALimitOrIsAnotherIsRefused() async throws {
    func deep(_ levels: Int) -> [String: Any] {
        var track: [String: Any] = ["position": "1", "title": "Deep", "duration": "1:00"]
        for _ in 0..<levels {
            track = ["position": "", "title": "Index", "sub_tracks": [track]]
        }
        return track
    }
    let rows = (0..<5_000).map { ["position": "\($0)", "title": "T\($0)"] }
    for (body, why) in [
        (changedRelease { $0["id"] = 1002 }, "came back as"),
        (changedRelease { $0["tracklist"] = rows }, "rows"),
        (changedRelease { $0["tracklist"] = [deep(8)] }, "deeper"),
        (changedRelease { $0["title"] = String(repeating: "x", count: 2_001) }, "characters"),
        (changedRelease { $0["title"] = 5 }, "title has the wrong type"),
        (changedRelease { $0["formats"] = [["name": "CD", "qty": 1]] }, "qty"),
        (changedRelease { $0.removeValue(forKey: "title") }, "title is missing"),
        (Array("<html>".utf8), "isn't JSON"),
    ] {
        let fake = FakeDiscogs()
        fake.queue("/releases/1001", status: 200, body: body)
        do {
            _ = try await fake.api().release(id: 1001)
            Issue.record("\(why) was accepted")
        } catch {
            guard case .malformed(let text) = error else {
                Issue.record("\(error)")
                continue
            }
            #expect(text.contains(why), "\(text)")
        }
    }
    // Three levels are kept.
    let fake = FakeDiscogs()
    fake.queue("/releases/1001", status: 200, body: changedRelease { $0["tracklist"] = [deep(2)] })
    #expect(try await fake.api().release(id: 1001).release.tracks.count == 1)
}

@Test func noErrorTextHoldsTheTokenOrTheQuery() async throws {
    let errors: [DiscogsAPIError] = [
        .tokenRequired, .unauthorized, .notFound, .rateLimited, .status(500), .offline,
        .timedOut, .tooLarge, .malformed("x"), .refusedAddress, .cancelled,
    ]
    for error in errors {
        #expect(!error.description.contains(fakeToken.secret))
        #expect(!error.description.contains("http"))
        #expect(!error.description.contains("barcode"))
    }
    // A decode failure says where, not what it read.
    let fake = FakeDiscogs()
    fake.queue(
        "/database/search", status: 200,
        body: Array(#"{"results": [{"id": "\#(fakeToken.secret)"}]}"#.utf8))
    do {
        _ = try await fake.api().search(barcode: "7 350001 000123")
        Issue.record("a bad search was accepted")
    } catch {
        #expect(!"\(error)".contains(fakeToken.secret))
        #expect(!"\(error)".contains("7 350001"))
    }
}

@Test func theCacheAnswersUntilItsEntryIsOldOrDamaged() async throws {
    let fake = FakeDiscogs()
    let api = fake.api()
    _ = try await api.release(id: 1001)
    let stored = try #require(fake.cacheEntry(.release, 1001))
    #expect(stored.fetchedAt == fake.now)
    #expect(!stored.json.contains(fakeToken.secret))
    // A hit makes no request.
    #expect(try await api.release(id: 1001).release.title == "Stockholm")
    #expect(fake.requests.count == 1)
    // An entry past the cache's age is fetched again and replaced.
    fake.advance(DiscogsAPI.cacheDays * 86_400 + 1)
    _ = try await api.release(id: 1001)
    #expect(fake.requests.count == 2)
    #expect(fake.cacheEntry(.release, 1001)?.fetchedAt == fake.now)
    // A damaged one, or one for another id, isn't trusted.
    for json in [#"{"i": 1001"#, #"{"i": 1002, "t": "x", "l": {}}"#] {
        fake.setCacheEntry(.release, 1001, (fake.now, json))
        #expect(try await api.release(id: 1001).release.title == "Stockholm")
        #expect(fake.cacheEntry(.release, 1001)?.json != json)
    }
    #expect(fake.requests.count == 4)
    // A master is cached as its main release.
    #expect(try await api.mainRelease(master: 500) == 1001)
    #expect(try await api.mainRelease(master: 500) == 1001)
    #expect(fake.requests.count == 5)
}
