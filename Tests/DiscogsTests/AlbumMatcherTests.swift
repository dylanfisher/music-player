import Foundation
import Library
import Testing

@testable import Discogs

/// A release in the dump's XML. `tracks` are `track(…)`s and `heading(…)`s.
private func release(
    _ id: Int, artist: String = "Persuader", anv: String? = nil, title: String = "Stockholm",
    master: Int? = nil, main: Bool = false, label: String = "Svek", catno: String = "SK 032",
    secondCatno: String? = nil,
    format: String = "CD", descriptions: [String] = [], released: String? = nil,
    country: String? = nil,
    barcode: String? = nil, tracks: [String]
) -> String {
    let descriptionsXML =
        descriptions.isEmpty
        ? ""
        : "<descriptions>"
            + descriptions.map { "<description>\($0)</description>" }.joined()
            + "</descriptions>"
    let releasedXML =
        (released.map { "<released>\($0)</released>" } ?? "")
        + (country.map { "<country>\($0)</country>" } ?? "")
    let secondXML = secondCatno.map { #"<label name="Other" catno="\#($0)" id="6"/>"# } ?? ""
    let anvXML = anv.map { "<anv>\($0)</anv>" } ?? ""
    let masterXML =
        master.map { #"<master_id is_main_release="\#(main)">\#($0)</master_id>"# } ?? ""
    let barcodeXML =
        barcode.map { #"<identifiers><identifier type="Barcode" value="\#($0)"/></identifiers>"# }
        ?? ""
    return
        #"<release id="\#(id)"><artists><artist><id>1</id><name>\#(artist)</name>\#(anvXML)</artist></artists><title>\#(title)</title><labels><label name="\#(label)" catno="\#(catno)" id="5"/>\#(secondXML)</labels><formats><format name="\#(format)" qty="1">\#(descriptionsXML)</format></formats>\#(releasedXML)\#(masterXML)<tracklist>\#(tracks.joined())</tracklist>\#(barcodeXML)</release>"#
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
    barcode: String? = nil, date: String? = nil, media: String? = nil, country: String? = nil,
    releaseIDs: [String?] = []
) -> DiscogsAlbum {
    DiscogsAlbum(
        id: 1, title: title, artist: artist, label: label, catalogNumber: catalogNumber,
        barcode: barcode, date: date, media: media, country: country,
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

@Test func aNumberSpelledAsTheTagsSpellItBeatsOneThatOnlyFoldsTheSame() throws {
    let releases =
        release(10, master: 100, catno: "VIVACE1001", format: "File", tracks: stockholm)
        + release(
            11, master: 100, main: true, catno: "vivace1001", format: "Vinyl", tracks: stockholm)
    let result = try match(
        album(stockholmTitles, catalogNumber: "vivace1001"), masters: master(100, main: 11),
        releases: releases)
    #expect(result.tier == .exact)
    #expect(result.releaseID == 11)
}

@Test func theFirstLabelsNumberAndTheBarcodeTogetherCountMost() throws {
    // CATALOGNUMBER is the first label's number: one on a second label counts less.
    let labels =
        release(10, master: 100, main: true, catno: "X 1", secondCatno: "8416", tracks: stockholm)
        + release(11, master: 100, catno: "8416", format: "Vinyl", tracks: stockholm)
    let first = try match(
        album(stockholmTitles, catalogNumber: "8416"), masters: master(100, main: 10),
        releases: labels)
    #expect(first.tier == .exact)
    #expect(first.releaseID == 11)
    // Both releases have the barcode; only one has the number as well.
    let both =
        release(
            10, master: 100, main: true, catno: "0888072340275", barcode: "8 88072 34027 5",
            tracks: stockholm)
        + release(
            11, master: 100, catno: "FAN-34027", format: "Vinyl", barcode: "8 88072 34027 5",
            tracks: stockholm)
    let result = try match(
        album(stockholmTitles, catalogNumber: "FAN-34027", barcode: "8 88072 34027 5"),
        masters: master(100, main: 10), releases: both)
    #expect(result.tier == .exact)
    #expect(result.releaseID == 11)
}

@Test func mediaAndDatesFitWhatDiscogsHasSinceFilledIn() throws {
    let releases =
        release(10, master: 100, main: true, released: "1966", tracks: stockholm)
        + release(
            11, master: 100, format: "Vinyl", descriptions: ["LP", "Stereo"],
            released: "1965-01-00", tracks: stockholm)
        + release(
            12, master: 100, format: "Vinyl", descriptions: ["LP", "Stereo"], released: "1966",
            tracks: stockholm)
    let result = try match(
        album(stockholmTitles, date: "1965", media: "Vinyl (LP)"), masters: master(100, main: 10),
        releases: releases)
    #expect(result.tier == .exact)
    #expect(result.releaseID == 11)
    let format = CatalogRelease.Format(name: "Vinyl", descriptions: ["LP", "Album", "Stereo"])
    #expect(fits("Vinyl (LP,Album)", format))
    #expect(fits("Vinyl (LP), CD (Album)", format))
    #expect(fits("Vinyl", format))
    #expect(!fits("Vinyl (LP,Mono)", format))
    #expect(!fits("CD (LP)", format))
    #expect(datesFit("1965", "1965-01-00"))
    #expect(datesFit("1965-01-15", "1965-01-00"))
    #expect(!datesFit("1965-02-00", "1965-01-00"))
    #expect(!datesFit("196", "1965"))
}

@Test func theTagsCountrySettlesReleasesTheDateDoesNot() throws {
    let releases =
        release(10, master: 100, main: true, released: "1965", country: "Canada", tracks: stockholm)
        + release(11, master: 100, released: "1965", country: "UK &amp; Europe", tracks: stockholm)
        + release(12, master: 100, released: "1965", country: "US", tracks: stockholm)
    let exact = try match(
        album(stockholmTitles, date: "1965", country: "US"), masters: master(100, main: 10),
        releases: releases)
    #expect(exact.tier == .exact)
    #expect(exact.releaseID == 12)
    // Discogs has since widened the country to a region.
    let fitted = try match(
        album(stockholmTitles, date: "1965", country: "UK"), masters: master(100, main: 10),
        releases: releases)
    #expect(fitted.tier == .exact)
    #expect(fitted.releaseID == 11)
    #expect(countriesFit("UK", "UK & Europe"))
    #expect(countriesFit("UK & Europe", "europe"))
    #expect(!countriesFit("UK", "US"))
    #expect(!countriesFit("", "US"))
}

@Test func aReleaseFitsTheFilesOrSaysWhyNotAndTagsCanBeOutdated() {
    let release = CatalogRelease(
        id: 1, title: "Stockholm", formats: [.init(name: "Vinyl", descriptions: ["LP", "Album"])],
        released: "1999-03-00",
        tracks: stockholmTitles.enumerated().map {
            CatalogTrack(kind: .track, position: "\($0.offset + 1)", title: $0.element)
        })
    #expect(releaseFit(album(stockholmTitles), release) == .fits)
    #expect(releaseFit(album(["Östermalm", "Gamla Stan"]), release) == .otherCount)
    #expect(releaseFit(album(["A", "B", "C"]), release) == .otherTitles)
    #expect(
        !tagsOutdate(album(stockholmTitles, date: "1999-03-00", media: "Vinyl (LP,Album)"), release)
    )
    // A date or descriptions Discogs has filled in since are a change too.
    #expect(tagsOutdate(album(stockholmTitles, date: "1999"), release))
    #expect(tagsOutdate(album(stockholmTitles, media: "Vinyl (LP)"), release))
    #expect(tagsOutdate(album(stockholmTitles, date: "2001"), release))
    #expect(tagsOutdate(album(stockholmTitles, media: "CD (Album)"), release))
}

@Test func aTwinIsTheSameReleaseInEveryTagTheMatcherCompares() {
    let base = CatalogRelease(
        id: 1, title: "Stockholm", labels: [.init(name: "Svek", catalogNumber: "SK 032")],
        formats: [.init(name: "Vinyl", descriptions: ["12\""])], country: "Sweden",
        released: "1999", barcodes: ["7 18755 61492 1"],
        tracks: [CatalogTrack(kind: .track, position: "A", title: "Östermalm")])
    var twin = base
    twin.id = 2
    twin.labels.append(.init(name: "Distributor", catalogNumber: "D 1"))
    twin.barcodes = ["718755614921", "123"]
    twin.tracks[0].position = "1"
    #expect(base.isTwin(of: twin))
    for change in [
        { (r: inout CatalogRelease) in r.country = "Germany" },
        { $0.released = "2000" }, { $0.formats[0].descriptions = ["LP"] },
        { $0.labels[0].catalogNumber = "SK 033" }, { $0.barcodes = ["1"] },
        { $0.tracks[0].title = "Other" },
    ] {
        var other = base
        change(&other)
        #expect(!base.isTwin(of: other))
    }
}

@Test func theTagsMediaThenTheirDateSettleReleasesOfOneNumber() throws {
    let releases =
        release(
            10, master: 100, main: true, descriptions: ["Album"], released: "1999",
            tracks: stockholm)
        + release(
            11, master: 100, format: "Vinyl", descriptions: ["LP", "Album"], released: "2001",
            tracks: stockholm)
        + release(
            12, master: 100, format: "Vinyl", descriptions: ["LP", "Album"], released: "2003",
            tracks: stockholm)
    let byMedia = try match(
        album(stockholmTitles, catalogNumber: "SK 032", media: "Vinyl (LP,Album)"),
        masters: master(100, main: 10), releases: releases)
    #expect(byMedia.tier == .likely)
    #expect(byMedia.releaseID == 11)
    let byDate = try match(
        album(stockholmTitles, catalogNumber: "SK 032", date: "2003", media: "Vinyl (LP,Album)"),
        masters: master(100, main: 10), releases: releases)
    #expect(byDate.tier == .exact)
    #expect(byDate.releaseID == 12)
}

@Test func aReleaseWhoseLengthsDisagreeStillTiesWithItsTwin() throws {
    // Discogs's lengths are typed in by hand: the release with wrong ones may be the one.
    let releases =
        release(10, master: 100, tracks: stockholm)
        + release(
            11, master: 100,
            tracks: ["Östermalm", "Gamla Stan", "Kungsholmen"].enumerated().map {
                track("\($0.offset + 1)", $0.element)
            })
    let result = try match(
        album(stockholmTitles, seconds: [285, 370, 420]), masters: master(100, main: 10),
        releases: releases)
    #expect(result.tier == .likely)
    #expect(result.candidates.map(\.releaseID) == [11])
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
    let matches = try await matchAlbums(albums, catalogAt: folder.catalog, choosing: [:]) { heard.add($0) }
    #expect(matches.map(\.tier) == [.exact, .exact, .exact])
    #expect(heard.all.map(\.albumsDone) == [1, 2, 3])
    #expect(heard.all.allSatisfy { $0.albumCount == 3 })

    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await matchAlbums(albums, catalogAt: folder.catalog, choosing: [:]) { _ in }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func matchingWithoutACatalogSaysSo() async throws {
    let folder = try DumpFolder()
    await #expect(throws: CatalogError.missing(folder.catalog.path)) {
        try await matchAlbums([album(stockholmTitles)], catalogAt: folder.catalog, choosing: [:]) { _ in }
    }
}

@Test func aChosenReleaseIsTheMatchTieredByItsOwnScore() throws {
    let folder = try DumpFolder()
    try folder.write(
        "20261101",
        releases: release(10, tracks: stockholm)
            + release(
                11, title: "Elsewhere", catno: "X 1",
                tracks: [track("1", "Östermalm"), track("2", "Gamla Stan"), track("3", "Other")])
            + release(12, title: "Unrelated", catno: "Y 1", tracks: [track("1", "Nothing")]))
    let matcher = AlbumMatcher(try folder.importedCatalog())
    #expect(try matcher.match(album(stockholmTitles)).releaseID == 10)
    let likely = try matcher.match(album(stockholmTitles), choosing: 11)
    #expect(likely.releaseID == 11)
    #expect(likely.tier == .likely)
    #expect(likely.candidates.map(\.releaseID) == [10])
    // Chosen though no key finds it: another title and catalog number.
    let unrelated = try matcher.match(album(stockholmTitles), choosing: 12)
    #expect(unrelated.releaseID == 12)
    #expect(unrelated.tier == .incomplete)
    // A choice the catalog doesn't have leaves the matcher's own.
    #expect(try matcher.match(album(stockholmTitles), choosing: 99).releaseID == 10)
}

@Test func theTracklistsSideBySideMarkEachRowAndADraggedRowSwaps() throws {
    var result = try match(
        album(["Östermalm", "Gamla Stan (Edit)", "Bonus"], seconds: [285, 370, 100]),
        releases: release(10, tracks: stockholm))
    let album = album(
        ["Östermalm", "Gamla Stan (Edit)", "Bonus"], seconds: [285, 370, 100])
    #expect(
        result.comparison(of: album).map(\.state) == [.matched, .matched, .different])
    result.assign(101, to: 2)
    let rows = result.comparison(of: album)
    #expect(rows.map(\.fileID) == [100, 102, 101])
    #expect(rows.map(\.state) == [.matched, .different, .different])
    result.assign(102, to: nil)
    let unmapped = result.comparison(of: album)
    #expect(unmapped.map(\.fileID) == [100, nil, 101, 102])
    #expect(unmapped.map(\.state) == [.matched, .missing, .different, .missing])
    #expect(unmapped[1].releaseTitle == "Gamla Stan")
    #expect(unmapped[3].fileTitle == "Bonus")
}

@Test func aReleasesSummaryIsWhatTheWindowShows() async throws {
    let folder = try DumpFolder()
    try folder.write(
        "20261101",
        releases: release(
            10, artist: "Persuader (2)", secondCatno: "O 2", format: "Vinyl",
            descriptions: ["LP", "Album"], released: "2000-03-00", country: "Sweden",
            tracks: stockholm))
    try folder.importCatalog()
    let summaries = try await releaseSummaries([99, 10], catalogAt: folder.catalog)
    #expect(
        summaries == [
            ReleaseSummary(
                id: 10, artist: "Persuader", title: "Stockholm", label: "Svek & Other",
                catalogNumber: "SK 032", country: "Sweden", year: "2000",
                format: "Vinyl (LP,Album)")
        ])
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
