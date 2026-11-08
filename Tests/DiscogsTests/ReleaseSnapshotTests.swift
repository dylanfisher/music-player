import Foundation
import Testing

@testable import Discogs
@testable import Recommender

private func track(_ position: String?, _ title: String, _ seconds: Int? = nil) -> CatalogTrack {
    CatalogTrack(kind: .track, position: position, title: title, durationSeconds: seconds)
}

private func release(
    artists: [CatalogArtistCredit] = [CatalogArtistCredit(id: 1, name: "Persuader")],
    title: String = "Stockholm", released: String? = "1999-03-00", _ tracks: [CatalogTrack]
) -> CatalogRelease {
    CatalogRelease(id: 10, title: title, artists: artists, released: released, tracks: tracks)
}

private func positions(_ snapshot: ReleaseSnapshot) -> [[String]] {
    snapshot.tracklists.map { $0.map(\.position) }
}

@Test func aPlainReleaseIsOneTracklistWithoutItsHeadings() throws {
    let snapshot = try ReleaseSnapshot(
        release([
            CatalogTrack(kind: .heading, position: nil, title: "Side A"),
            track("A1", "Östermalm", 285), track("A2", "Gamla Stan"),
        ]))
    #expect(
        snapshot
            == ReleaseSnapshot(
                releaseID: 10, artist: "Persuader", title: "Stockholm", year: 1999,
                tracklists: [
                    [
                        .init(position: "A1", title: "Östermalm", seconds: 285),
                        .init(position: "A2", title: "Gamla Stan", seconds: nil),
                    ]
                ]))
}

@Test func indexTracksGiveBothFlatteningsThePartsFirst() throws {
    let suite = CatalogTrack(
        kind: .index, position: nil, title: "Suite",
        subTracks: [track("2a", "Allegro", 100), track("2b", "Adagio", 200)])
    let snapshot = try ReleaseSnapshot(
        release([track("1", "Prelude", 60), suite, track("3", "Coda")]))
    #expect(positions(snapshot) == [["1", "2a", "2b", "3"], ["1", "2a+2b", "3"]])
    #expect(snapshot.tracklists[1][1] == .init(position: "2a+2b", title: "Suite", seconds: 300))
}

@Test func theArtistIsDiscogssSpellingWithItsJoinsAndAYearOnlyWhenThereIsOne() throws {
    let artists = [
        CatalogArtistCredit(id: 1, name: "Persuader (2)", join: "&"),
        CatalogArtistCredit(id: 2, name: "Friend"),
    ]
    let snapshot = try ReleaseSnapshot(release(artists: artists, released: nil, [track("1", "A")]))
    #expect(snapshot.artist == "Persuader & Friend")
    #expect(snapshot.year == nil)
    let various = try ReleaseSnapshot(
        release(artists: [CatalogArtistCredit(id: 194, name: "Various")], [track("1", "A")]))
    #expect(various.artist == "Various")
}

@Test func aReleaseWithNoPositionsAtAllIsNumberedInOrder() throws {
    let snapshot = try ReleaseSnapshot(release([track(nil, "A"), track(nil, "B")]))
    #expect(positions(snapshot) == [["1", "2"]])
}

@Test func aTracklistTheServiceWouldRefuseIsRefusedHere() {
    let refused: [(CatalogRelease, ReleaseSnapshot.Problem)] = [
        (release([track("1", "A"), track("1", "B")]), .positions(releaseID: 10)),
        (release([track("1", "A"), track(nil, "B")]), .positions(releaseID: 10)),
        (release([]), .trackCount(releaseID: 10, 0)),
        (
            release((0...ReleaseSnapshot.trackCap).map { track("\($0)", "T") }),
            .trackCount(releaseID: 10, ReleaseSnapshot.trackCap + 1)
        ),
        (release(title: "", [track("1", "A")]), .unnamed(releaseID: 10)),
        (release(artists: [], [track("1", "A")]), .unnamed(releaseID: 10)),
    ]
    for (release, problem) in refused {
        #expect(throws: problem) { try ReleaseSnapshot(release) }
    }
}

@Test func queueingAReleaseNotInTheLocalCatalogIsRefused() throws {
    let folder = try DumpFolder()
    try folder.write(
        "20261101",
        releases:
            #"<release id="10"><artists><artist><id>1</id><name>Persuader</name></artist></artists><title>Stockholm</title><tracklist><track><position>1</position><title>Östermalm</title><duration>4:45</duration></track></tracklist></release>"#
            + "\n")
    try folder.importCatalog()
    let queued = try ReleaseSnapshot.queueable(releaseID: 10, catalogAt: folder.catalog)
    #expect(queued.tracklists == [[.init(position: "1", title: "Östermalm", seconds: 285)]])
    #expect(throws: ReleaseSnapshot.Problem.notInCatalog(releaseID: 11)) {
        try ReleaseSnapshot.queueable(releaseID: 11, catalogAt: folder.catalog)
    }
    #expect(
        ReleaseSnapshot.Problem.notInCatalog(releaseID: 11).description
            == "release 11 is not in the local catalog")
}
