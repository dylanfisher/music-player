import Foundation
import Testing

@testable import Library
@testable import Metadata
@testable import Settings

@Test func eachCheckFindsWhatItLooksFor() throws {
    let tracks = [
        Crafted(
            path: "/M/A/01.flac", title: "One", album: "A", albumArtist: "X", disc: 1, number: 1,
            seconds: 100),
        Crafted(
            path: "/M/A/02.flac", title: "Two", album: "A", albumArtist: "X", disc: 1, number: 1),
        Crafted(
            path: "/M/A/04.flac", title: "Four", album: "A", albumArtist: "X", disc: 1, number: 4,
            rateHz: 96000),
        Crafted(
            path: "/M/B/01.flac", title: "One", album: "B", albumArtist: "Y", number: 1,
            seconds: 100.9),
        Crafted(path: "/M/B/02.flac", title: "Other", album: "B", number: 2),
        Crafted(path: "/M/B/03.flac", title: "Third", album: "B", albumArtist: "Q", number: 3),
        Crafted(path: "/M/C/01.flac", title: "One", seconds: 102, art: false),
        Crafted(
            path: "/M/D/01.flac", title: "Warned", album: "D", albumArtist: "Z", number: 1,
            warning: true),
        Crafted(path: "/M/D/02.flac", title: "Gone", album: "D", albumArtist: "Z", number: 2),
    ]
    let index = try craftedIndex(tracks.map(\.scanned) + [failed("/M/bad.flac")])
    let playlist = try index.createPlaylist(named: "Mix", rules: nil)
    _ = try index.addToPlaylist(
        playlist, trackIDs: try ids(index, ["/M/D/02.flac", "/M/A/01.flac"]))
    // A file read before that can't be now loses its track, and leaves its playlist entry.
    try index.store([failed("/M/D/02.flac")])

    let report = try index.healthReport()
    #expect(report[.unreadable].trackIDs.isEmpty)
    #expect(
        report[.unreadable].lines == [
            "/M/D/02.flac: failure malformed: no header (at byte 8)",
            "/M/bad.flac: failure malformed: no header (at byte 8)",
        ])
    #expect(report[.warnings].trackIDs == (try ids(index, ["/M/D/01.flac"])))
    #expect(report[.missingEntries].lines == ["Mix: /M/D/02.flac"])
    #expect(report[.missingEntries].count == 1)
    #expect(report[.sameNumber].trackIDs == (try ids(index, ["/M/A/01.flac", "/M/A/02.flac"])))
    // 100 and 100.9 seconds are within a second; 102 isn't within one of 100.9.
    #expect(report[.sameTitle].trackIDs == (try ids(index, ["/M/A/01.flac", "/M/B/01.flac"])))
    // Album A has 1, 1 and 4: 2 and 3 are missing. B's 2 has no album artist and 3 has Q, so
    // each is an album of its own without a 1. D's 2 left with its track, so D has 1 alone.
    #expect(
        report[.trackGaps].trackIDs
            == (try ids(
                index,
                ["/M/A/01.flac", "/M/A/02.flac", "/M/A/04.flac", "/M/B/02.flac", "/M/B/03.flac"])))
    // B in one folder under Y and Q: every track of it, the one with none too.
    #expect(
        report[.severalAlbumArtists].trackIDs
            == (try ids(index, ["/M/B/01.flac", "/M/B/02.flac", "/M/B/03.flac"])))
    #expect(
        report[.mixedSampleRates].trackIDs
            == (try ids(index, ["/M/A/01.flac", "/M/A/02.flac", "/M/A/04.flac"])))
    #expect(report[.noArt].trackIDs == (try ids(index, ["/M/C/01.flac"])))
    #expect(report[.noAlbum].trackIDs == (try ids(index, ["/M/C/01.flac"])))
    #expect(
        report[.noAlbumArtist].trackIDs == (try ids(index, ["/M/B/02.flac", "/M/C/01.flac"])))
}

@Test func aCleanLibraryHasNothingToReport() throws {
    let index = try craftedIndex([
        Crafted(path: "/M/A/01.flac", title: "One", album: "A", albumArtist: "X", number: 1)
            .scanned,
        Crafted(path: "/M/A/02.flac", title: "Two", album: "A", albumArtist: "X", number: 2)
            .scanned,
    ])
    let report = try index.healthReport()
    #expect(HealthCheck.allCases.allSatisfy { report[$0].count == 0 })
}

@Test func theTitleSweepLinksNeighborsWithinASecondOnly() {
    func track(_ id: Int64, _ title: String, _ artist: Int64, _ seconds: Double) -> TitledTrack {
        TitledTrack(id: id, title: title, artist: artist, seconds: seconds)
    }
    let sorted = [
        track(1, "A", 1, 10), track(2, "A", 1, 11), track(3, "A", 1, 12.01),
        track(4, "A", 2, 12.01), track(5, "B", 2, 12.5), track(6, "B", 2, 30),
        track(7, "C", 3, 5), track(8, "C", 3, 5),
    ]
    // Exactly a second apart counts; 1.01 doesn't; another artist or title never does.
    #expect(sameTitleAndLength(sorted) == [1, 2, 7, 8])
    #expect(sameTitleAndLength([]) == [])
}

@Test func otherItemsAreListedUpToTheCapThenCounted() {
    let findings = HealthFindings(others: (0..<(healthLinesListed + 5)).map { "line \($0)" })
    #expect(findings.otherCount == healthLinesListed + 5)
    #expect(findings.lines.count == healthLinesListed + 1)
    #expect(findings.lines.last == "… and 5 more")
    #expect(findings.count == healthLinesListed + 5)
}

@Test func aHealthSourceListsTheShownReportsTracks() throws {
    let index = try craftedIndex([
        Crafted(path: "/M/A/01.flac", title: "One", album: "A").scanned,
        Crafted(path: "/M/C/01.flac", title: "Two", art: false).scanned,
    ])
    let filter = TrackFilter(source: .health(.noArt))
    // Nothing until a report is shown on this connection.
    #expect(try index.trackIDs(filter, sortedBy: .title).isEmpty)
    try index.showHealth(try index.healthReport())
    #expect(try index.trackIDs(filter, sortedBy: .title) == (try ids(index, ["/M/C/01.flac"])))
    #expect(try index.albums(filter).isEmpty)
    #expect(try index.trackIDs(TrackFilter(source: .health(.noAlbum)), sortedBy: .title).count == 1)
    // A second report replaces the first.
    try index.store([Crafted(path: "/M/C/01.flac", title: "Two").scanned])
    try index.showHealth(try index.healthReport())
    #expect(try index.trackIDs(filter, sortedBy: .title).isEmpty)
}
