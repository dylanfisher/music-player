import Foundation
import Library
import Testing

@testable import Discogs

/// A release in the dump's XML. `tracks` are `track(…)`s and `heading(…)`s.
private func release(
    _ id: Int, artist: String = "Persuader", anv: String? = nil, title: String = "Stockholm",
    master: Int? = nil, main: Bool = false, label: String = "Svek", catno: String = "SK 032",
    format: String = "CD", barcode: String? = nil, tracks: [String]
) -> String {
    let anvXML = anv.map { "<anv>\($0)</anv>" } ?? ""
    let masterXML =
        master.map { #"<master_id is_main_release="\#(main)">\#($0)</master_id>"# } ?? ""
    let barcodeXML =
        barcode.map { #"<identifiers><identifier type="Barcode" value="\#($0)"/></identifiers>"# }
        ?? ""
    return
        #"<release id="\#(id)"><artists><artist><id>1</id><name>\#(artist)</name>\#(anvXML)</artist></artists><title>\#(title)</title><labels><label name="\#(label)" catno="\#(catno)" id="5"/></labels><formats><format name="\#(format)" qty="1"></format></formats>\#(masterXML)<tracklist>\#(tracks.joined())</tracklist>\#(barcodeXML)</release>"#
        + "\n"
}

private func track(_ position: String, _ title: String, _ duration: String = "") -> String {
    "<track><position>\(position)</position><title>\(title)</title><duration>\(duration)</duration></track>"
}

private func heading(_ title: String) -> String {
    "<track><position></position><title>\(title)</title><duration></duration></track>"
}

private func index(_ title: String, _ parts: [String]) -> String {
    "<track><position></position><title>\(title)</title><sub_tracks>\(parts.joined())</sub_tracks></track>"
}

private func master(_ id: Int, main: Int, artist: String = "Persuader", title: String = "Stockholm")
    -> String
{
    #"<master id="\#(id)"><main_release>\#(main)</main_release><artists><artist><id>1</id><name>\#(artist)</name></artist></artists><title>\#(title)</title></master>"#
        + "\n"
}

/// Stockholm's three tracks, as Discogs lists them.
private let stockholm = [
    track("1", "Östermalm", "4:45"), track("2", "Gamla Stan", "6:10"),
    track("3", "Kungsholmen", "5:00"),
]

/// An album with a track per title, each `seconds` long, numbered from 1.
private func album(
    _ titles: [String], seconds: [Double] = [285, 370, 300], artist: String? = "Persuader",
    title: String = "Stockholm", label: String? = nil, catalogNumber: String? = nil,
    barcode: String? = nil, releaseIDs: [String?] = []
) -> DiscogsAlbum {
    DiscogsAlbum(
        id: 1, title: title, artist: artist, label: label, catalogNumber: catalogNumber,
        barcode: barcode,
        tracks: titles.enumerated().map { number, title in
            DiscogsAlbum.Track(
                fileID: Int64(100 + number), title: title,
                seconds: number < seconds.count ? seconds[number] : 200, trackNumber: number + 1,
                releaseID: number < releaseIDs.count ? releaseIDs[number] : nil)
        })
}

private let stockholmTitles = ["Östermalm", "Gamla Stan", "Kungsholmen"]

/// Matches `album` against a catalog of `releases` and `masters`.
private func match(_ album: DiscogsAlbum, masters: String = "", releases: String) throws
    -> AlbumMatch
{
    let folder = try DumpFolder()
    try folder.write("20261101", masters: masters, releases: releases)
    return try AlbumMatcher(try folder.importedCatalog()).match(album)
}

@Test func anAlbumThatFitsOneReleaseIsExactWithEachFileOnItsTrack() throws {
    let result = try match(album(stockholmTitles), releases: release(10, tracks: stockholm))
    #expect(result.tier == .exact)
    #expect(result.releaseID == 10)
    #expect(result.mapping == [100: 0, 101: 1, 102: 2])
    #expect(result.tracks.map(\.position) == ["1", "2", "3"])
    #expect(result.candidates.isEmpty)
}

@Test func aTracklistThatFitsWellButNotEveryTitleIsLikely() throws {
    let result = try match(
        album(["Östermalm", "Gamla Stan", "Something Else Entirely"]),
        releases: release(10, tracks: stockholm))
    #expect(result.tier == .likely)
    #expect(result.releaseID == 10)
}

@Test func lengthsThatDisagreeMakeAnExactTracklistLikely() throws {
    let result = try match(
        album(stockholmTitles, seconds: [285, 370, 420]), releases: release(10, tracks: stockholm))
    #expect(result.tier == .likely)
    // Within the tolerance is agreeing.
    let close = try match(
        album(stockholmTitles, seconds: [287.5, 368, 300]), releases: release(10, tracks: stockholm)
    )
    #expect(close.tier == .exact)
}

@Test func aBonusTrackMakesTheAlbumIncompleteWithTheRestMapped() throws {
    let result = try match(
        album(
            ["Östermalm", "Bonus Beat", "Gamla Stan", "Kungsholmen"], seconds: [285, 100, 370, 300]),
        releases: release(10, tracks: stockholm))
    #expect(result.tier == .incomplete)
    #expect(result.releaseID == 10)
    #expect(result.mapping == [100: 0, 102: 1, 103: 2])
}

@Test func aHiddenTrackTheAlbumLacksMakesItIncomplete() throws {
    let result = try match(
        album(stockholmTitles),
        releases: release(10, tracks: stockholm + [track("4", "Untitled Hidden Track", "1:00")]))
    #expect(result.tier == .incomplete)
    #expect(result.mapping == [100: 0, 101: 1, 102: 2])
}

@Test func anAlbumNothingIsFoundForHasNoCandidate() throws {
    let result = try match(
        album(stockholmTitles, artist: "Nobody", title: "Nothing"),
        releases: release(10, tracks: stockholm))
    #expect(result.tier == .noCandidate)
    #expect(result.releaseID == nil)
    #expect(result.mapping.isEmpty)
}

@Test func anAlbumWithOneReleaseIDIsMatchedToThatReleaseThoughAnotherFits() throws {
    let result = try match(
        album(stockholmTitles, releaseIDs: ["11", "11", "11"]),
        releases: release(10, tracks: stockholm)
            + release(11, tracks: [track("1", "Other", "1:00")]))
    #expect(result.tier == .matched)
    #expect(result.releaseID == 11)
    #expect(result.candidates.map(\.releaseID) == [10])
}

@Test func anAlbumWithSomeOrMixedReleaseIDsIsIncomplete() throws {
    let releases = release(10, tracks: stockholm) + release(11, tracks: stockholm)
    for ids in [["10", nil, "10"], ["10", "11", "10"]] {
        let result = try match(album(stockholmTitles, releaseIDs: ids), releases: releases)
        #expect(result.tier == .incomplete, "\(ids)")
        #expect(result.releaseID == 10, "\(ids)")
    }
}

@Test func releasesThatFitEquallyAreSettledByTheCatalogNumberInTheTagsFirst() throws {
    // The tags' catalog number beats a CD that is the master's main release.
    let releases =
        release(10, master: 100, main: true, catno: "SK 1", tracks: stockholm)
        + release(11, master: 100, catno: "SK 2", format: "Vinyl", tracks: stockholm)
    let byNumber = try match(
        album(stockholmTitles, label: "Svek", catalogNumber: "SK-2"),
        masters: master(100, main: 10), releases: releases)
    #expect(byNumber.tier == .exact)
    #expect(byNumber.releaseID == 11)
    #expect(byNumber.candidates.map(\.releaseID) == [10])
}

@Test func releasesThatFitEquallyAreSettledByTheBarcodeInTheTags() throws {
    let releases =
        release(10, master: 100, main: true, tracks: stockholm)
        + release(11, master: 100, barcode: "7 18755 61492 1", tracks: stockholm)
    let result = try match(
        album(stockholmTitles, barcode: "718755614921"), masters: master(100, main: 10),
        releases: releases)
    #expect(result.tier == .exact)
    #expect(result.releaseID == 11)
}

@Test func withoutANumberInTheTagsACDOrFileBeatsVinylThenTheMainReleaseWins() throws {
    let vinylMain =
        release(10, master: 100, main: true, format: "Vinyl", tracks: stockholm)
        + release(11, master: 100, format: "File", tracks: stockholm)
    let digital = try match(
        album(stockholmTitles), masters: master(100, main: 10), releases: vinylMain)
    #expect(digital.tier == .exact)
    #expect(digital.releaseID == 11)

    let twoCDs =
        release(10, master: 100, tracks: stockholm)
        + release(11, master: 100, main: true, tracks: stockholm)
    let main = try match(album(stockholmTitles), masters: master(100, main: 11), releases: twoCDs)
    #expect(main.tier == .exact)
    #expect(main.releaseID == 11)
}

@Test func releasesStillTiedAfterTheTieBreakMakeTheAlbumLikely() throws {
    let releases =
        release(10, master: 100, tracks: stockholm) + release(11, master: 100, tracks: stockholm)
        + release(12, master: 100, main: true, format: "Vinyl", tracks: stockholm)
    let result = try match(
        album(stockholmTitles), masters: master(100, main: 12), releases: releases)
    #expect(result.tier == .likely)
    #expect(result.releaseID == 10)
    #expect(result.candidates.map(\.releaseID) == [11, 12])
}

@Test func aMultiDiscSetWithHeadingsIsExact() throws {
    let tracks = [
        heading("Disc One"), track("1-1", "Östermalm", "4:45"), track("1-2", "Gamla Stan", "6:10"),
        heading("Disc Two"), track("2-1", "Kungsholmen", "5:00"),
    ]
    let result = try match(album(stockholmTitles), releases: release(10, tracks: tracks))
    #expect(result.tier == .exact)
    #expect(result.tracks.map(\.position) == ["1-1", "1-2", "2-1"])
}

@Test func vinylPositionsAreExact() throws {
    let tracks = [
        heading("Side A"), track("A1", "Östermalm", "4:45"), track("A2", "Gamla Stan", "6:10"),
        track("B", "Kungsholmen", "5:00"),
    ]
    let result = try match(
        album(stockholmTitles), releases: release(10, format: "Vinyl", tracks: tracks))
    #expect(result.tier == .exact)
}

@Test func anIndexTrackIsItsPartsOrOneFile() throws {
    let tracks = [
        track("1", "Östermalm", "4:45"),
        index("Suite", [track("2a", "Gamla Stan", "6:10"), track("2b", "Kungsholmen", "5:00")]),
    ]
    let parts = try match(album(stockholmTitles), releases: release(10, tracks: tracks))
    #expect(parts.tier == .exact)
    #expect(parts.tracks.map(\.title) == stockholmTitles)

    let whole = try match(
        album(["Östermalm", "Suite"], seconds: [285, 670]), releases: release(10, tracks: tracks))
    #expect(whole.tier == .exact)
    #expect(whole.tracks.map(\.title) == ["Östermalm", "Suite"])
}

@Test func aTracklistWithNoPositionsHasNoHeadings() throws {
    let tracks = ["Östermalm", "Gamla Stan", "Kungsholmen"].map { heading($0) }
    let result = try match(album(stockholmTitles), releases: release(10, tracks: tracks))
    #expect(result.tier == .exact)
}

@Test func anArtistWithADiscogsSuffixOrAnANVIsFoundByItsName() throws {
    // Discogs's "Soleil (2)", tagged as "Soleil".
    let suffixed = try match(
        album(stockholmTitles, artist: "Soleil"),
        releases: release(10, artist: "Soleil (2)", tracks: stockholm))
    #expect(suffixed.tier == .exact)
    // A credit printed with an ANV is found by the canonical name, which the owner's tags use
    // (ADR 0128), and by the catalog number when tagged with the ANV.
    let canonical = try match(
        album(stockholmTitles, artist: "Jesper Dahlbäck"),
        releases: release(10, artist: "Jesper Dahlbäck", anv: "Dahlbäck", tracks: stockholm))
    #expect(canonical.tier == .exact)
    let variation = try match(
        album(stockholmTitles, artist: "Dahlbäck", label: "Svek", catalogNumber: "SK 032"),
        releases: release(10, artist: "Jesper Dahlbäck", anv: "Dahlbäck", tracks: stockholm))
    #expect(variation.tier == .exact)
}

@Test func titlesAndArtistsAreAlsoTriedTheOtherWaysTheyAreTagged() throws {
    let releases = release(10, tracks: stockholm)
    for (artist, title) in [
        ("Persuader", "[SK 032] Stockholm"), ("Persuader", "Stockholm - 2011 Remaster"),
        ("Persuader feat. Soleil", "Stockholm"), ("Persuader & Soleil", "Stockholm"),
    ] {
        let result = try match(
            album(stockholmTitles, artist: artist, title: title), releases: releases)
        #expect(result.tier == .exact, "\(artist), \(title)")
    }
    let compilation = try match(
        album(stockholmTitles, artist: nil),
        releases: release(10, artist: "Various", tracks: stockholm))
    #expect(compilation.tier == .exact)
    let tagged = try match(
        album(stockholmTitles, artist: "Various Artists"),
        releases: release(10, artist: "Various", tracks: stockholm))
    #expect(tagged.tier == .exact)
}

@Test func matchingReportsProgressAndStopsWhenCancelled() async throws {
    let folder = try DumpFolder()
    try folder.write("20261101", releases: release(10, tracks: stockholm))
    try folder.importCatalog()
    let albums = (0..<3).map { _ in album(stockholmTitles) }
    let heard = Heard()
    let matches = try await matchAlbums(albums, catalogAt: folder.catalog) { heard.add($0) }
    #expect(matches.map(\.tier) == [.exact, .exact, .exact])
    #expect(heard.all.map(\.albumsDone) == [1, 2, 3])
    #expect(heard.all.allSatisfy { $0.albumCount == 3 })

    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await matchAlbums(albums, catalogAt: folder.catalog) { _ in }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func matchingWithoutACatalogSaysSo() async throws {
    let folder = try DumpFolder()
    await #expect(throws: CatalogError.missing(folder.catalog.path)) {
        try await matchAlbums([album(stockholmTitles)], catalogAt: folder.catalog) { _ in }
    }
}

/// The progress a run reported, from its thread.
private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [AlbumMatchProgress] = []

    func add(_ report: AlbumMatchProgress) {
        lock.lock()
        reports.append(report)
        lock.unlock()
    }

    var all: [AlbumMatchProgress] {
        lock.lock()
        defer { lock.unlock() }
        return reports
    }
}
