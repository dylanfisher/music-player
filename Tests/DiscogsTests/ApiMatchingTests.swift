import Foundation
import HTTPSClient
import Library
import Settings
import Testing

@testable import Discogs
@testable import Fixtures

/// An album with a file per title, numbered from 1.
private func album(
    _ id: Int64, _ titles: [String], seconds: [Double] = [285, 370, 300],
    artist: String = "Persuader", title: String = "Stockholm", barcode: String? = nil,
    releaseIDs: [String?] = []
) -> DiscogsAlbum {
    DiscogsAlbum(
        id: id, title: title, artist: artist, label: nil, catalogNumber: nil, barcode: barcode,
        date: nil, media: nil, country: nil,
        tracks: titles.enumerated().map { number, title in
            DiscogsAlbum.Track(
                fileID: id * 100 + Int64(number), title: title,
                seconds: number < seconds.count ? seconds[number] : 200, trackNumber: number + 1,
                releaseID: number < releaseIDs.count ? releaseIDs[number] : nil)
        })
}

private let stockholm = ["Östermalm", "Gamla Stan", "Kungsholmen"]

/// One album of each tier the fixtures can make.
private let tiered = [
    // Its barcode finds 1001, which fits it exactly.
    album(1, stockholm, barcode: "7 350001 000123"),
    // A title off: the three-track releases fit it, but not exactly.
    album(2, ["Östermalm", "Gamla Stan", "Kungsholm"]),
    // A file more than the three-track releases have, and a title off the four-track one.
    album(3, stockholm + ["Bonus"], seconds: [285, 370, 300, 200], barcode: "7 350001 000123"),
    album(4, ["Nothing"], artist: "Nobody", title: "Nothing"),
]

/// A folder with the release fixtures imported as a catalog, as the dump has them.
private func fixtureCatalog() throws -> DumpFolder {
    let folder = try DumpFolder()
    try folder.write("20261101", masters: apiDumpMasters, releases: apiDumpReleases)
    try folder.importCatalog()
    return folder
}

private func run(
    _ albums: [DiscogsAlbum], _ source: DiscogsSource, catalog: URL, api: DiscogsAPI?,
    choosing chosen: [Int64: Int] = [:], heard: Recorded<AlbumMatchProgress> = .init()
) async throws -> [AlbumMatch] {
    try await matchAlbums(
        albums, catalogAt: catalog, source: source, api: api, choosing: chosen,
        skippingVideo: false
    ) { heard.add($0) }
}

@Test func theAPITiersAlbumsAsTheCatalogDoesForTheSameReleases() async throws {
    let folder = try fixtureCatalog()
    let fromCatalog = try await run(tiered, .catalog, catalog: folder.catalog, api: nil)
    let fake = FakeDiscogs()
    let fromAPI = try await run(tiered, .api, catalog: folder.catalog, api: fake.api())
    #expect(fromCatalog.map(\.tier) == [.exact, .likely, fromCatalog[2].tier, .noCandidate])
    #expect(fromAPI.map(\.tier) == fromCatalog.map(\.tier))
    #expect(fromAPI[0].releaseID == 1001)
    #expect(fromCatalog[0].releaseID == 1001)
    #expect(fromAPI[0].origin == .api)
    #expect(fromCatalog[0].origin == .catalog)
    #expect(fromAPI[3].releaseID == nil)
}

@Test func theAPIAloneWorksWithNoCatalogFileAndTheCatalogStillSaysItsMissing() async throws {
    let folder = try DumpFolder()
    let fake = FakeDiscogs()
    let matches = try await run(
        [tiered[0]], .api, catalog: folder.catalog, api: fake.api())
    #expect(matches.first?.tier == .exact)
    await #expect(throws: CatalogError.missing(folder.catalog.path)) {
        try await run([tiered[0]], .catalog, catalog: folder.catalog, api: fake.api())
    }
}

@Test func withoutATokenOnlyTaggedAlbumsAreLookedUpAndNothingSearches() async throws {
    let folder = try DumpFolder()
    let fake = FakeDiscogs()
    let tagged = album(5, stockholm, releaseIDs: ["1006", "1006", "1006"])
    let matches = try await run(
        [tagged, tiered[0]], .api, catalog: folder.catalog, api: fake.api(token: nil))
    #expect(matches.map(\.tier) == [.matched, .noCandidate])
    #expect(matches.first?.releaseID == 1006)
    #expect(fake.requests.map(\.url.path) == ["/releases/1006"])
}

@Test func bothAsksTheAPIOnlyAboutAlbumsTheCatalogCantPlace() async throws {
    let folder = try DumpFolder()
    // A catalog without release 1005, which the tags of one album name.
    try folder.write("20261101", masters: apiDumpMasters, releases: apiDumpReleases)
    try folder.importCatalog()
    let fake = FakeDiscogs()
    let newer = album(
        6, ["Matin", "Soir"], seconds: [210, 3723], artist: "Soleil", title: "Duos",
        releaseIDs: ["1007", "1007"])
    fake.queue("/releases/1007", status: 200, body: renumbered("release-anv-variations", 1007))
    let matches = try await run(
        [tiered[0], newer, tiered[3]], .both, catalog: folder.catalog, api: fake.api())
    #expect(matches.map(\.tier) == [.exact, .matched, .noCandidate])
    #expect(matches[0].origin == .catalog)
    #expect(matches[1].releaseID == 1007)
    #expect(matches[1].origin == .api)
    // Not one request for the exact album: the tagged id, and the searches for it and the
    // no-candidate album.
    let paths = fake.requests.map(\.url.path)
    #expect(paths.filter { $0 != "/database/search" } == ["/releases/1007"])
    #expect(!fake.requests.contains { $0.url.query?.contains("7%20350001") == true })
}

/// A release fixture's JSON with its id changed, for a release the catalog doesn't have.
private func renumbered(_ name: String, _ id: Int) -> [UInt8] {
    var object = try! JSONSerialization.jsonObject(with: Data(apiFixture(name))) as! [String: Any]
    object["id"] = id
    return Array(try! JSONSerialization.data(withJSONObject: object))
}

@Test func aChosenReleaseTheCatalogLacksIsFetched() async throws {
    let folder = try fixtureCatalog()
    let fake = FakeDiscogs()
    fake.queue("/releases/1009", status: 200, body: renumbered("release-simple", 1009))
    let matches = try await run(
        [tiered[0]], .both, catalog: folder.catalog, api: fake.api(), choosing: [1: 1009])
    #expect(matches.first?.releaseID == 1009)
    #expect(matches.first?.origin == .api)
    #expect(fake.requests.contains { $0.url.path == "/releases/1009" })
}

@Test func atMostEightReleasesAreFetchedForAnAlbum() async throws {
    let folder = try DumpFolder()
    let fake = FakeDiscogs()
    let results = (2001...2012).map { #"{"id": \#($0), "type": "release"}"# }
    fake.queue(
        "/database/search", status: 200,
        body: Array(#"{"results": [\#(results.joined(separator: ","))]}"#.utf8))
    _ = try await run(
        [album(7, stockholm, barcode: "123")], .api, catalog: folder.catalog, api: fake.api())
    let fetched = fake.requests.filter { $0.url.path.hasPrefix("/releases/") }
    #expect(fetched.count == ApiCandidates.maximumReleases)
    #expect(fetched.first?.url.path == "/releases/2001")
}

@Test func releasesSharingAMasterAskItOnceAndItsMainReleaseWinsTheTie() async throws {
    let folder = try DumpFolder()
    let fake = FakeDiscogs()
    fake.queue(
        "/masters/500", status: 200,
        body: Array(#"{"id": 500, "main_release": 1006, "title": "Stockholm"}"#.utf8))
    let matches = try await run(
        [album(8, stockholm)], .api, catalog: folder.catalog, api: fake.api())
    // The title search finds 1002 and 1006, of master 500, which fit alike.
    #expect(matches.first?.releaseID == 1006)
    #expect(fake.requests.filter { $0.url.path == "/masters/500" }.count == 1)
}

@Test func anErrorThatStopsTheRunIsThrownAndAMissingReleaseIsLeftOut() async throws {
    let folder = try DumpFolder()
    let fake = FakeDiscogs()
    let tagged = album(9, stockholm, releaseIDs: ["4040", "4040", "4040"])
    let matches = try await run([tagged], .api, catalog: folder.catalog, api: fake.api())
    #expect(matches.first?.tier == .matched)
    #expect(matches.first?.release == nil)
    for (reply, thrown) in [
        (Result<HTTPSResponse, HTTPSError>.failure(.offline), DiscogsAPIError.offline),
        (.failure(.timedOut), .timedOut),
        (.success(HTTPSResponse(status: 401, headers: [:], body: [])), .unauthorized),
    ] {
        // A fake of its own, whose cache doesn't hold 1006 yet.
        let fresh = FakeDiscogs()
        fresh.queue("/releases/1006", reply)
        await #expect(throws: thrown) {
            try await run(
                [album(10, stockholm, releaseIDs: ["1006", "1006", "1006"])], .api,
                catalog: folder.catalog, api: fresh.api())
        }
    }
}

@Test func cancellingDuringARateLimitWaitStopsTheRun() async throws {
    let folder = try DumpFolder()
    let fake = FakeDiscogs()
    let api = DiscogsAPI(
        token: fakeToken, userAgent: "MusicPlayer/1.0", transport: fake.transport,
        cache: fake.cache, now: { fake.now },
        sleep: { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) })
    fake.queue("/database/search", status: 429, headers: ["Retry-After": "120"])
    let heard = Recorded<AlbumMatchProgress>()
    let task = Task {
        try await run([tiered[0]], .api, catalog: folder.catalog, api: api, heard: heard)
    }
    // Cancelled once the run says it waits, which a fixed pause missed on a loaded Mac.
    let deadline = Date().addingTimeInterval(waitLimit)
    while !heard.all.contains(where: { $0.waitingSeconds == 120 }), Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(heard.all.contains { $0.waitingSeconds == 120 })
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func bothCountsTheAPIsAlbumsApartAndReportsAWait() async throws {
    let folder = try fixtureCatalog()
    let fake = FakeDiscogs()
    fake.queue(
        "/database/search", status: 200,
        headers: ["X-Discogs-Ratelimit": "60", "X-Discogs-Ratelimit-Remaining": "0"],
        body: apiFixture("search-empty"))
    let heard = Recorded<AlbumMatchProgress>()
    _ = try await run(
        [tiered[0], tiered[3], album(11, ["Nada"], artist: "Nobody", title: "Nada")], .both,
        catalog: folder.catalog, api: fake.api(), heard: heard)
    let reports = heard.all
    #expect(reports.first == AlbumMatchProgress(albumsDone: 1, albumCount: 3))
    #expect(reports.contains { $0.waitingSeconds == 60 && $0.apiAlbumsDone == 1 })
    #expect(
        reports.last
            == AlbumMatchProgress(
                albumsDone: 3, albumCount: 3, apiAlbumsDone: 2, apiAlbumCount: 2))
}

@Test func theSheetsReadAnAPIReleaseFromTheCacheWithNoRequest() async throws {
    let folder = try DumpFolder()
    let fake = FakeDiscogs()
    let api = fake.api()
    _ = try await api.release(id: 1005)
    let requests = fake.requests.count
    let summaries = try await releaseSummaries([1005, 4040], catalogAt: folder.catalog, api: api)
    #expect(summaries.map(\.id) == [1005])
    #expect(summaries.first?.title == "Duos")
    let detail = try await releaseDetail(1005, catalogAt: folder.catalog, api: api)
    #expect(detail?.tracks.map(\.title) == ["Matin", "Soir"])
    #expect(fake.requests.count == requests)
    await #expect(throws: CatalogError.missing(folder.catalog.path)) {
        try await releaseSummaries([1005], catalogAt: folder.catalog)
    }
}

@Test func aRunWithinARunGivesTheWaitsBackWhenItEnds() async throws {
    let folder = try DumpFolder()
    let fake = FakeDiscogs()
    let api = fake.api()
    let outer = Recorded<Int?>()
    await api.setWaiting { outer.add($0) }
    // A short run, as choosing a release makes, with its own progress.
    _ = try await run([tiered[0]], .api, catalog: folder.catalog, api: api)
    fake.queue("/releases/1002", status: 429, headers: ["Retry-After": "40"])
    _ = try await api.release(id: 1002)
    #expect(outer.all == [40, nil])
}

@Test func bothKeepsTheCatalogsMatchesWhenTheAPIStopsAndTheAPIAloneDoesnt() async throws {
    let folder = try fixtureCatalog()
    let fake = FakeDiscogs()
    fake.queue("/database/search", .failure(.offline))
    do {
        _ = try await run([tiered[0], tiered[3]], .both, catalog: folder.catalog, api: fake.api())
        Issue.record("the stop wasn't reported")
    } catch let stopped as APIStoppedMatching {
        #expect(stopped.error == .offline)
        #expect(stopped.matches.map(\.tier) == [.exact, .noCandidate])
        #expect(stopped.matches.first?.releaseID == 1001)
    }
    let alone = FakeDiscogs()
    alone.queue("/database/search", .failure(.offline))
    await #expect(throws: DiscogsAPIError.offline) {
        try await run([tiered[3]], .api, catalog: folder.catalog, api: alone.api())
    }
}

/// After an API run, the sheets and Choose ask Discogs nothing more (ADR 0170): Other
/// Releases reads the cache, a cover fetches its image only, and choosing another release
/// scores it alone, with the other candidates kept and no search.
@Test func choosingAReleaseAfterAnAPIRunSendsNoSearch() async throws {
    let folder = try DumpFolder()
    let fake = FakeDiscogs()
    let api = fake.api()
    let stockholmAlbum = album(8, stockholm)
    let first = try #require(
        try await run([stockholmAlbum], .api, catalog: folder.catalog, api: api).first)
    let other = try #require(first.candidates.first?.releaseID)
    let before = fake.requests.count
    #expect(fake.requests.contains { $0.url.path == "/database/search" }, "the run searched")

    let ids = [try #require(first.releaseID)] + first.candidates.map(\.releaseID)
    let summaries = try await releaseSummaries(ids, catalogAt: folder.catalog, api: api)
    #expect(summaries.map(\.id) == ids)
    _ = try? await api.cover(release: other)
    #expect(
        fake.requests.dropFirst(before).allSatisfy { $0.url.host == DiscogsAPI.imageHost },
        "a cover fetches its image, nothing else")

    let chosen = try await chooseRelease(
        other, for: stockholmAlbum, after: first, catalogAt: folder.catalog, source: .api,
        api: api)
    #expect(chosen.releaseID == other)
    #expect(chosen.origin == .api)
    #expect(chosen.tier == .exact, "scored alone, so no longer tied")
    #expect(Set(chosen.candidates.map(\.releaseID)) == Set(ids).subtracting([other]))
    #expect(chosen.reasons.isEmpty)
    #expect(
        fake.requests.dropFirst(before).allSatisfy { $0.url.host == DiscogsAPI.imageHost },
        "choosing sent no request")
}

/// With the catalog as the source, a chosen release comes from the catalog alone, and one it
/// lacks is an error, not a fallback to the matcher's own choice.
@Test func choosingFromTheCatalogReadsItAlone() async throws {
    let folder = try fixtureCatalog()
    let album = tiered[1]
    let first = try #require(
        try await run([album], .catalog, catalog: folder.catalog, api: nil).first)
    let other = try #require(first.candidates.first?.releaseID)
    let chosen = try await chooseRelease(
        other, for: album, after: first, catalogAt: folder.catalog, source: .catalog, api: nil)
    #expect(chosen.releaseID == other)
    #expect(chosen.origin == .catalog)
    #expect(chosen.candidates.contains { $0.releaseID == first.releaseID })
    #expect(chosen.foundBy == .title, "found as the run found it")
    await #expect(throws: ReleaseNotInCatalog(releaseID: 4040)) {
        try await chooseRelease(
            4040, for: album, after: first, catalogAt: folder.catalog, source: .catalog,
            api: nil)
    }
}
