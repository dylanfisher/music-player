import Foundation
import Library
import SQLite
import Testing

@testable import Discogs

/// An album of Stockholm's three tracks, untagged.
private let stockholm = DiscogsAlbum(
    id: 1, title: "Stockholm?", artist: nil,
    tracks: [("Östermalm", 285.0), ("Gamla Stan", 370), ("Kungsholmen", 300)].enumerated().map {
        DiscogsAlbum.Track(fileID: Int64($0.offset), title: $0.element.0, seconds: $0.element.1)
    })

@Test func aReleaseIDIsReadAsAPastedOneIs() {
    for typed in ["1001", " r1001 ", "https://www.discogs.com/release/1001-Persuader-Stockholm"] {
        #expect(ReleaseQuery(release: typed).releaseID == 1001, "\(typed)")
    }
    for typed in ["", "Stockholm", "r", "1001x", "https://www.discogs.com/master/500"] {
        #expect(ReleaseQuery(release: typed).releaseID == nil, "\(typed)")
    }
    #expect(ReleaseQuery(artist: " ").isEmpty)
    #expect(!ReleaseQuery(catalogNumber: "SK 032").isEmpty)
    #expect(!ReleaseQuery(release: "r1").isEmpty)
}

@Test func theCatalogIsAskedFirstAndTheAPINotWhenItFindsOne() async throws {
    let folder = try DumpFolder()
    try folder.write("20261101", masters: apiDumpMasters, releases: apiDumpReleases)
    try folder.importCatalog()
    let fake = FakeDiscogs()
    let api = fake.api()
    func ids(_ query: ReleaseQuery) async throws -> Set<Int> {
        let found = try await lookUpReleases(
            query, for: stockholm, catalogAt: folder.catalog, api: api)
        #expect(found.origin == .catalog, "\(query)")
        return Set(found.releases.map(\.summary.id))
    }
    #expect(try await ids(ReleaseQuery(release: "r1004")) == [1004])
    // The master's releases, by the artist and title as tagged or with an edition's words.
    #expect(
        try await ids(ReleaseQuery(artist: "Persuader", title: "Stockholm (Remastered)"))
            == [1001, 1002, 1003, 1006])
    #expect(try await ids(ReleaseQuery(artist: "persuader")) == [1001, 1002, 1003, 1004, 1006])
    #expect(try await ids(ReleaseQuery(title: "Suites")) == [1004])
    // A catalog number on any label, and every other field given must hold too.
    #expect(try await ids(ReleaseQuery(catalogNumber: "sk-032")) == [1001, 1003, 1006])
    #expect(
        try await ids(ReleaseQuery(artist: "Persuader", title: "Stock", catalogNumber: "SK032"))
            == [1001, 1003, 1006])
    #expect(fake.requests.isEmpty, "the API isn't asked")

    // Best fit first: the three-track CDs above the vinyl with a fourth track.
    let found = try await lookUpReleases(
        ReleaseQuery(catalogNumber: "SK 032"), for: stockholm, catalogAt: folder.catalog, api: api)
    #expect(found.releases.last?.summary.id == 1003)
    #expect(found.releases.map(\.score) == found.releases.map(\.score).sorted(by: >))
}

/// The fields given filter the releases before the list is cut, so the one wanted isn't
/// dropped behind hundreds the fields rule out; a release id is looked up alone.
@Test func theFieldsFilterBeforeTheListIsCut() async throws {
    let release = { (id: Int, artist: String) in
        #"<release id="\#(id)"><artists><artist><id>9</id><name>\#(artist)</name></artist></artists><title>Same Number</title><labels><label name="Svek" catno="SK 1" id="5"/></labels></release>"#
    }
    let others = (1...300).map { release($0, "Somebody Else") }
    let folder = try DumpFolder()
    try folder.write(
        "20261101", releases: (others + [release(400, "Persuader")]).joined(separator: "\n") + "\n")
    try folder.importCatalog()
    let found = try await lookUpReleases(
        ReleaseQuery(artist: "Persuader", catalogNumber: "SK 1"), for: stockholm,
        catalogAt: folder.catalog, api: nil)
    #expect(found.releases.map(\.summary.id) == [400])
    #expect(!found.isCut)
    let all = try await lookUpReleases(
        ReleaseQuery(catalogNumber: "SK 1"), for: stockholm, catalogAt: folder.catalog, api: nil)
    #expect(all.releases.count == 200 && all.isCut)

    let byID = ReleaseQuery(artist: "Somebody Else", release: "r400")
    #expect(byID.ignoresOtherFields)
    #expect(!ReleaseQuery(release: "r400").ignoresOtherFields)
    let alone = try await lookUpReleases(
        byID, for: stockholm, catalogAt: folder.catalog, api: nil)
    #expect(alone.releases.map(\.summary.id) == [400], "the artist typed beside it is ignored")
}

/// A catalog that can't be read stops the search with why, rather than passing for none.
@Test func aCatalogThatCantBeReadStopsTheSearch() async throws {
    let folder = try DumpFolder()
    try folder.write("20261101", masters: apiDumpMasters, releases: apiDumpReleases)
    try folder.importCatalog()
    try Database(at: folder.catalog).execute("UPDATE catalog SET schema = 'other'")
    let fake = FakeDiscogs()
    await #expect(throws: CatalogError.builtByAnotherVersion(folder.catalog.path)) {
        try await lookUpReleases(
            ReleaseQuery(title: "Stockholm"), for: stockholm, catalogAt: folder.catalog,
            api: fake.api())
    }
    #expect(fake.requests.isEmpty)
}

@Test func theAPIIsAskedWhenTheCatalogHasNoMatchOrIsntThere() async throws {
    let folder = try DumpFolder()
    try folder.write("20261101", masters: apiDumpMasters, releases: apiDumpReleases)
    try folder.importCatalog()
    let fake = FakeDiscogs()
    let api = fake.api()
    // The catalog has Persuader's Stockholm, but not under another artist.
    let found = try await lookUpReleases(
        ReleaseQuery(artist: "Someone Else", title: "Stockholm"), for: stockholm,
        catalogAt: folder.catalog, api: api)
    #expect(found.origin == .api)
    #expect(found.releases.map(\.summary.id).sorted() == [1002, 1006])
    let search = try #require(fake.requests.first?.url)
    #expect(search.path == "/database/search")
    #expect(search.query?.contains("artist=Someone%20Else") == true)
    #expect(search.query?.contains("release_title=Stockholm") == true)
    #expect(search.query?.contains("catno") == false, "an empty field isn't sent")

    let missing = folder.directory.appendingPathComponent("none.sqlite", isDirectory: false)
    let byID = try await lookUpReleases(
        ReleaseQuery(release: "r1005"), for: stockholm, catalogAt: missing,
        api: fake.api(token: nil))
    #expect(byID.origin == .api)
    #expect(byID.releases.map(\.summary.id) == [1005], "an id needs no token")
    let unknown = try await lookUpReleases(
        ReleaseQuery(release: "999"), for: stockholm, catalogAt: missing, api: api)
    #expect(unknown.releases.isEmpty)
    await #expect(throws: DiscogsAPIError.tokenRequired) {
        try await lookUpReleases(
            ReleaseQuery(title: "Stockholm"), for: stockholm, catalogAt: missing,
            api: fake.api(token: nil))
    }
}
