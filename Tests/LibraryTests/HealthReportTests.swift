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

    let report = try index.healthReport(measuredChecks: { _ in [] })
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
    let report = try index.healthReport(measuredChecks: { _ in [] })
    #expect(HealthCheck.allCases.allSatisfy { report[$0].count == 0 })
}

/// The measured checks list the tracks whose current measures earn them, and count the tracks
/// analyzed; measures of a file since changed, or of no track, count for nothing.
@Test func theMeasuredChecksReadTheCurrentMeasuresOfTheTracks() throws {
    let index = try craftedIndex(
        ["/M/a.flac", "/M/b.flac", "/M/c.flac", "/M/d.flac"].map { Crafted(path: $0).scanned })
    func measures(_ runs: Int) -> FileMeasures {
        FileMeasures(
            formatID: "flac", sampleRateHz: 44_100, storedBits: 16, channels: 2, isFloat: false,
            durationSeconds: 200, cutoffHz: nil, cutoffSteepnessDBPerKHz: nil,
            effectiveBits: 16, identicalChannels: false, peakDBFS: -1, truePeakDBTP: -1,
            clippedRuns: runs, dynamicRange: 10)
    }
    // Crafted files are 1 byte, modified at 1 s.
    let current = FileStamp(sizeBytes: 1, modifiedSeconds: 1)
    try index.storeMeasures(measures(20), path: "/M/a.flac", stamp: current)
    try index.storeMeasures(measures(0), path: "/M/b.flac", stamp: current)
    try index.storeMeasures(
        measures(20), path: "/M/c.flac", stamp: FileStamp(sizeBytes: 2, modifiedSeconds: 1))
    try index.storeMeasures(measures(20), path: "/M/gone.flac", stamp: current)

    let report = try index.healthReport(measuredChecks: { measures in
        measures.clippedRuns > 10 ? [.clipped, .fakeStereo] : []
    })
    #expect(report.analyzedCount == 2)
    #expect(report[.clipped].trackIDs == (try ids(index, ["/M/a.flac"])))
    #expect(report[.fakeStereo].trackIDs == (try ids(index, ["/M/a.flac"])))
    #expect(report[.lossyOrigin].count == 0)

    #expect(HealthCheck.clipped.summary(analyzedCount: nil) == HealthCheck.clipped.summary)
    #expect(
        HealthCheck.clipped.summary(analyzedCount: 0)
            == "Files with runs of samples at full scale; none analyzed yet")
    #expect(
        HealthCheck.clipped.summary(analyzedCount: 1204)
            == "Files with runs of samples at full scale, of 1,204 files analyzed")
    #expect(HealthCheck.noArt.summary(analyzedCount: 1204) == HealthCheck.noArt.summary)
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
    try index.showHealth(try index.healthReport(measuredChecks: { _ in [] }))
    #expect(try index.trackIDs(filter, sortedBy: .title) == (try ids(index, ["/M/C/01.flac"])))
    #expect(try index.albums(filter).isEmpty)
    #expect(try index.trackIDs(TrackFilter(source: .health(.noAlbum)), sortedBy: .title).count == 1)
    // A second report replaces the first.
    try index.store([Crafted(path: "/M/C/01.flac", title: "Two").scanned])
    try index.showHealth(try index.healthReport(measuredChecks: { _ in [] }))
    #expect(try index.trackIDs(filter, sortedBy: .title).isEmpty)
}

@Test func releasesInOtherFoldersAndDiscsAreKeptApart() throws {
    func track(
        _ path: String, _ album: String, disc: Int? = nil, _ number: Int, rateHz: Int = 44100
    )
        -> ScannedFile
    {
        Crafted(
            path: path, title: path, album: album, albumArtist: "B", disc: disc, number: number,
            rateHz: rateHz
        ).scanned
    }
    let index = try craftedIndex([
        // One title and album artist, two releases in two folders.
        track("/M/Iron 1990/01.flac", "Iron", 1), track("/M/Iron 1990/02.flac", "Iron", 2),
        track("/M/Iron 2008/01.flac", "Iron", 1, rateHz: 96000),
        track("/M/Iron 2008/02.flac", "Iron", 2, rateHz: 96000),
        // A box set with a folder per disc, each disc numbered from 1.
        track("/M/Box/CD1/01.flac", "Box", disc: 1, 1),
        track("/M/Box/CD1/02.flac", "Box", disc: 1, 2),
        track("/M/Box/CD2/01.flac", "Box", disc: 2, 1),
        track("/M/Box/CD2/02.flac", "Box", disc: 2, 2),
        // Discs in one folder, the second going on from the first's numbers.
        track("/M/Run/01.flac", "Run", disc: 1, 1), track("/M/Run/02.flac", "Run", disc: 1, 2),
        track("/M/Run/03.flac", "Run", disc: 2, 3), track("/M/Run/04.flac", "Run", disc: 2, 4),
        // The same, but with 4 missing from the second disc.
        track("/M/Holes/01.flac", "Holes", disc: 1, 1),
        track("/M/Holes/02.flac", "Holes", disc: 1, 2),
        track("/M/Holes/03.flac", "Holes", disc: 2, 3),
        track("/M/Holes/05.flac", "Holes", disc: 2, 5),
        // Two tracks whose length isn't known.
        Crafted(path: "/M/x/1.flac", title: "Same", seconds: 0).scanned,
        Crafted(path: "/M/y/1.flac", title: "Same", seconds: 0).scanned,
    ])
    let report = try index.healthReport(measuredChecks: { _ in [] })
    #expect(report[.sameNumber].trackIDs.isEmpty)
    #expect(report[.mixedSampleRates].trackIDs.isEmpty)
    #expect(
        report[.trackGaps].trackIDs == (try ids(index, ["/M/Holes/03.flac", "/M/Holes/05.flac"])))
    #expect(report[.sameTitle].trackIDs.isEmpty)
}
