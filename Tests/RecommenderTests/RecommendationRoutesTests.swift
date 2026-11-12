import Foundation
import Testing

@testable import Recommender

/// The filters the contract's example request sends.
private func everyFilter() -> RecommendationQuery.Filters {
    var filters = RecommendationQuery.Filters()
    filters.missing = true
    filters.styles = ["Deep House"]
    filters.yearFrom = 1990
    filters.yearTo = 1999
    filters.labels = [RecommendationPage.Named(id: 30, name: "Seed Records")]
    return filters
}

@Test func aListRequestSendsOnlyTheFieldsSet() async throws {
    let stub = try await StubService(
        Array(repeating: (200, try fixture("recommendations.json")), count: 6))
    defer { stub.stop() }
    let client = try stub.client
    _ = try await client.recommendations(RecommendationQuery(), offset: 0)
    _ = try await client.recommendations(
        RecommendationQuery(
            seed: .album(releaseID: 4242, title: "Made-Up Album"), filters: everyFilter()),
        offset: 100, limit: 50)
    _ = try await client.recommendations(
        RecommendationQuery(
            seed: .artist("Made-Up Artist"), show: .artists, filters: everyFilter()),
        offset: 0)
    _ = try await client.recommendations(
        RecommendationQuery(
            filters: {
                var f = RecommendationQuery.Filters()
                f.yearTo = 1999
                return f
            }()),
        offset: 0)
    _ = try await client.recommendations(RecommendationQuery(sort: .wantHave), offset: 0)
    _ = try await client.recommendations(
        RecommendationQuery(show: .artists, sort: .rating), offset: 0)
    #expect(
        stub.requests.map(\.bodyText) == [
            #"{"limit":100,"list":"library","offset":0,"show":"albums"}"#,
            #"{"label_ids":[30],"limit":50,"list":"album","missing":true,"offset":100,"#
                + #""release_id":4242,"show":"albums","styles":["Deep House"],"year_from":1990,"#
                + #""year_to":1999}"#,
            #"{"artist":"Made-Up Artist","limit":100,"list":"artist","offset":0,"show":"artists"}"#,
            #"{"limit":100,"list":"library","offset":0,"show":"albums","year_to":1999}"#,
            #"{"limit":100,"list":"library","offset":0,"show":"albums","sort":"want_have"}"#,
            #"{"limit":100,"list":"library","offset":0,"show":"artists"}"#,
        ])
    for request in stub.requests {
        #expect(request.head.hasPrefix("POST /v1/recommendations HTTP/1.1\r\n"))
        #expect(request.head.contains("\r\nAuthorization: Bearer s3cret-token\r\n"))
        #expect(!request.bodyText.contains(testToken.secret))
    }
}

@Test func theContractsPagesDecode() throws {
    let page = try decodeReply(
        Array(try fixture("recommendations.json").utf8), as: RecommendationPage.self)
    #expect(page.list.candidates == 848755)
    #expect(page.more)
    #expect(page.artists == nil)
    let album = try #require(page.albums?.first)
    #expect(album.kind == .release && album.releaseID == 2003 && album.year == 2001)
    #expect(album.label == RecommendationPage.Named(id: 30, name: "Seed Records"))
    #expect(album.community?.status == .fetched)
    #expect(album.community?.values?.ratingCount == 87)
    #expect(album.community?.values?.lowestPrice == nil)
    #expect(album.reasons.first?.kind == .credit)
    #expect(album.reasons.first?.seedRoles == ["Producer"])

    let artists = try decodeReply(Array(try artistsPage().utf8), as: RecommendationPage.self)
    #expect(artists.albums == nil)
    #expect(artists.artists?.first?.best == album)
    #expect(artists.artists?.first?.name == "Gus Other")
}

/// An artists page whose one artist's best album is the contract's example album.
private func artistsPage() throws -> String {
    let text = try fixture("recommendations.json")
    let start = try #require(text.range(of: #"[\#n  {"kind""#))
    let end = try #require(text.range(of: #"]}]}],"#))
    let album = String(text[text.index(after: start.lowerBound)..<end.upperBound].dropLast(2))
    return
        #"{"ok": true, "list": {"catalog_set": "20261001", "computed_at": 1, "seeds": 1, "candidates": 1}, "albums": null, "artists": [{"rank": 1, "id": 23, "name": "Gus Other", "score": 1, "albums": 1, "best": \#(album)}], "more": false}"#
}

@Test func aPageWithAValueOrFieldNotInTheContractFailsNamingIt() throws {
    let text = try fixture("recommendations.json")
    let cases = [
        (
            text.replacingOccurrences(of: #""kind": "credit""#, with: #""kind": "made_up""#),
            "albums.0.reasons.0.kind", "made_up"
        ),
        (
            text.replacingOccurrences(of: #""status": "fetched""#, with: #""status": "late""#),
            "albums.0.community.status", "late"
        ),
        (text.replacingOccurrences(of: #""rank": 4,"#, with: ""), "albums.0", "rank"),
        (
            text.replacingOccurrences(of: #""seeds": 3950,"#, with: #""seeds": 3950, "extra": 1,"#),
            "list.extra", "unknown key"
        ),
    ]
    for (reply, field, value) in cases {
        do throws(RecommenderError.Kind) {
            _ = try decodeReply(Array(reply.utf8), as: RecommendationPage.self)
            Issue.record("\(field) decoded")
        } catch {
            guard case .unreadable(let why) = error else {
                Issue.record("\(field) gave \(error)")
                continue
            }
            #expect(why.contains(field) && why.contains(value), "\(why)")
        }
    }
}

@Test func theProfileGoesAsItsExportedBytes() async throws {
    let stub = try await StubService([(200, try fixture("profile.json"))])
    defer { stub.stop() }
    let profile = LibraryProfile(albums: [
        LibraryProfile.Album(
            key: "a812", artist: "Made-Up Artist", title: "Made-Up Album", durations: [245],
            catalogNumbers: [], barcodes: [], discogsReleaseID: 4242, plays: 1, loved: 0,
            lastPlayed: 1_793_000_000, skips: 0)
    ])
    #expect(
        try await stub.client.sendProfile(profile)
            == ProfileReceipt(albums: 3, withReleaseID: 2, queued: 2))
    let request = try #require(stub.requests.first)
    #expect(request.head.hasPrefix("POST /v1/profile HTTP/1.1\r\n"))
    #expect(request.body == Array(profile.json()))
    #expect(!request.bodyText.contains(testToken.secret))
}

@Test func aProfileReplyWithAFieldNotInTheContractFails() {
    let reply = #"{"ok": true, "albums": 3, "with_release_id": 2, "queued": 2, "kept": true}"#
    #expect(throws: RecommenderError.Kind.unreadable("kept: unknown key")) {
        try decodeReply(Array(reply.utf8), as: ProfileReceipt.self)
    }
}

@Test func theListsRefusalsDecodeWithTheirCodes() throws {
    let codes: [(String, ServiceRefusal.Code)] = [
        ("no_catalog", .noCatalog), ("no_profile", .noProfile), ("no_list", .noList),
        ("no_seed", .noSeed),
    ]
    for (code, expected) in codes {
        #expect(
            throws: RecommenderError.Kind.refused(ServiceRefusal(code: expected, message: "no"))
        ) {
            try decodeReply(Array(failure(code).utf8), as: RecommendationPage.self)
        }
    }
    for rebuilding in [true, false] {
        var refusal = ServiceRefusal(code: .outOfDate, message: "x")
        refusal.rebuilding = rebuilding
        let body =
            #"{"ok": false, "error": {"code": "out_of_date", "message": "x", "rebuilding": \#(rebuilding)}}"#
        #expect(throws: RecommenderError.Kind.refused(refusal)) {
            try decodeReply(Array(body.utf8), as: RecommendationPage.self)
        }
    }
}

@Test func aBusyListIsA503WithItsCode() async throws {
    let stub = try await StubService([(503, failure("busy"))])
    defer { stub.stop() }
    let client = try stub.client
    #expect(
        await caught { () async throws(RecommenderError) in
            try await client.recommendations(RecommendationQuery(), offset: 0)
        }?.kind == .status(503, code: "busy"))
}
