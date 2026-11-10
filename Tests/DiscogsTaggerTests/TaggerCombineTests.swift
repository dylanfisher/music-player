import AppKit
import Foundation
import Library
import Testing

@testable import Discogs
@testable import DiscogsTagger
@testable import Metadata
@testable import Settings
@testable import TagWriter

// Combine Albums for Tagging (ADR 0179): the selection's albums joined into one for the tagger.

/// `album`, its files on disc `disc`.
private func onDisc(_ disc: Int?, _ album: DiscogsAlbum) -> DiscogsAlbum {
    var album = album
    for index in album.tracks.indices { album.tracks[index].discNumber = disc }
    return album
}

private let original = album(1, "1983", titles: ["Intro", "Song"])
private let reissue = album(2, "1983 [Expanded Reissue]", titles: ["Intro", "Song", "Bonus"])
private let other = album(3, "Other", titles: ["X"])
/// Every title of the two, as one release of the whole count has them.
private let wholeTitles = ["Intro", "Song", "Intro", "Song", "Bonus"]

/// Each album matched to a release of its own count, the combination to one of five tracks;
/// a chosen release taken as asked.
private let matches: @Sendable (DiscogsAlbum, Int?) -> AlbumMatch = { album, chosen in
    let titles = album.tracks.map { $0.title ?? "" }
    return match(
        album, release(chosen ?? Int(abs(album.id)) * 10, "1983", titles: titles), tier: .exact)
}

@Test func combiningOrdersTheAlbumsByDiscThenTitleAndKeepsEachInItsOwnOrder() {
    let second = onDisc(2, album(5, "Set (CD2)", titles: ["C", "D"]))
    let first = onDisc(1, album(6, "Set (CD1)", titles: ["A", "B"]))
    var withLabel = first
    withLabel.label = nil
    var labelled = second
    labelled.label = "Svek"
    let byDisc = CombinedAlbum([labelled, withLabel])
    #expect(byDisc.sources.map(\.id) == [6, 5])
    #expect(byDisc.album.tracks.map(\.title) == ["A", "B", "C", "D"])
    #expect(byDisc.album.id == -6, "an id no library album has")
    #expect(byDisc.album.title == "Set (CD1)", "the first album's, for the search")
    #expect(byDisc.album.label == "Svek", "the first detail any album has")

    // Two albums of the same disc aren't interleaved; no disc number is disc 1.
    let same = CombinedAlbum([reissue, onDisc(1, original)])
    #expect(same.sources.map(\.id) == [1, 2], "by title: the shorter first")
    #expect(same.album.tracks.map(\.fileID) == [100, 101, 200, 201, 202])
    #expect(same.titlesDiffer)
    #expect(!same.artistsDiffer)
    #expect(
        CombinedAlbum([original, album(4, "1983", artist: "Other", titles: ["A"])]).artistsDiffer)
    #expect(
        CombinedAlbum.title(same.sources)
            == "Persuader – 1983 + Persuader – 1983 [Expanded Reissue]")
    #expect(
        CombinedAlbum.text(same.sources)
            == "Combined from 2 albums: Persuader – 1983 (2 files) · Persuader – 1983 [Expanded"
            + " Reissue] (3 files)")
}

@MainActor
@Test func theCombinedScopeMatchesTheSelectedAlbumsAsOne() async throws {
    let seen = Seen()
    let tagger = await model(seen, albums: [original, reissue, other], matches: matches)
    tagger.scope = .combined
    tagger.selectedTracks = { [original.tracks[0].fileID, reissue.tracks[2].fileID] }
    tagger.analyze()
    await tagger.finished()
    #expect(seen.matched.count == 1, "one match of one album")
    let combined = try #require(tagger.albums.first)
    #expect(tagger.albums.count == 1)
    #expect(combined.id == -1)
    #expect(combined.album.tracks.map(\.fileID) == [100, 101, 200, 201, 202])
    #expect(combined.match.releaseID == 10, "a release of the whole count")
    #expect(combined.sources.map(\.id) == [1, 2])
    #expect(combined.title == "Persuader – 1983 + Persuader – 1983 [Expanded Reissue]")
    #expect(tagger.status.hasPrefix("Analyzed 1 albums"))
    #expect(tagger.selectedID == -1)

    // The selection scope still matches them apart.
    tagger.scope = .selection
    tagger.analyze()
    await tagger.finished()
    #expect(tagger.albums.map(\.id).sorted() == [1, 2])
    #expect(tagger.albums.allSatisfy { $0.sources.isEmpty })
}

@MainActor
@Test func aCombinedAlbumTakesAReviewOnlyWhenEveryAlbumHasIt() async throws {
    for (reviews, taken) in [
        ([1: DiscogsReview.chosen(releaseID: 70), 2: .chosen(releaseID: 70)], 70),
        ([1: .chosen(releaseID: 70)], nil),
        ([1: .chosen(releaseID: 70), 2: .chosen(releaseID: 71)], nil),
    ] as [([Int64: DiscogsReview], Int?)] {
        let seen = Seen()
        let tagger = await model(
            seen, albums: [original, reissue], matches: matches, reviews: reviews)
        tagger.scope = .combined
        tagger.selectedTracks = { [100, 200] }
        tagger.analyze()
        await tagger.finished()
        #expect(seen.matched.count == 1)
        #expect(seen.matched.first?[-1] == taken, "\(reviews)")
        #expect(tagger.albums.first?.chosen == taken)
    }
}

@MainActor
@Test func combiningOneAlbumSaysSoAndKeepsTheAlbumsShown() async throws {
    let seen = Seen()
    let tagger = await model(seen, albums: [original, reissue], matches: matches)
    var failures: [String] = []
    tagger.failed = { message, _ in failures.append(message) }
    tagger.analyze()
    await tagger.finished()
    tagger.scope = .combined
    tagger.selectedTracks = { [100, 101] }
    tagger.analyze()
    await tagger.finished()
    #expect(failures == ["Only one album is selected"])
    #expect(tagger.albums.map(\.id).sorted() == [1, 2], "the last run's")
    #expect(tagger.status.hasPrefix("Nothing to combine"))
    #expect(seen.matched.count == 1, "nothing was matched")
}

/// The files of albums with different titles get the release's title, which the Minimal
/// mapping leaves alone, so they become one album; Apply's question names the albums.
@MainActor
@Test func aCombinedAlbumsFilesGetOneTitleAndTheQuestionNamesItsAlbums() async throws {
    let sources = [original, reissue]
    for (titles, written) in [
        (sources, true), ([original, album(2, "1983", titles: ["B"])], false),
    ] {
        let seen = Seen()
        let tagger = await model(
            seen, albums: titles, matches: matches,
            files: { ids in
                titles.flatMap { album in album.tracks.indices.map { file(album, $0) } }
                    .filter { ids.contains($0.id) }
            })
        tagger.scope = .combined
        tagger.selectedTracks = { [100, 200] }
        tagger.analyze()
        await tagger.finished()
        let (set, _) = try #require(try await tagger.changeSet(for: -1))
        let albumChanges = set.files.flatMap(\.changes).filter { $0.field == .album }
        #expect(albumChanges.count == (written ? set.files.count : 0), "\(written)")
        #expect(albumChanges.allSatisfy { $0.new == "1983" })
        #expect(set.files.flatMap(\.changes).allSatisfy { $0.field != .albumArtist })

        let plan = try #require(await tagger.plan([-1]))
        #expect(plan.combined == [CombinedAlbum.text(tagger.albums[0].sources)])
        let (_, detail) = TaggerModel.confirmation(plan)
        #expect(detail.contains(CombinedAlbum.text(tagger.albums[0].sources)))
        #expect(detail.contains("Their files become one album of the release."))
    }
}

/// The window names the combined album's albums in its list, the row's tooltip and a line
/// over the tracklists, which no other album shows.
@MainActor
@Test func theWindowNamesEveryAlbumACombinedOneJoins() async throws {
    let tagger = await model(Seen(), albums: [original, reissue], matches: matches)
    tagger.scope = .combined
    tagger.selectedTracks = { [100, 200] }
    tagger.analyze()
    await tagger.finished()
    let controller = TaggerWindow(model: tagger)
    let sources = tagger.albums[0].sources
    #expect(
        controller.text(controller.albumTable, .album, 0)
            == "Persuader – 1983 + Persuader – 1983 [Expanded Reissue]")
    let cell = controller.tableView(
        controller.albumTable, viewFor: controller.albumTable.tableColumns[0], row: 0)
    #expect(cell?.toolTip == CombinedAlbum.text(sources, separator: "\n"))
    #expect(!controller.combinedLine.isHidden)
    #expect(controller.combinedLine.stringValue == CombinedAlbum.text(sources))
    #expect(controller.scopePopUp.titleOfSelectedItem == "Selected Albums as One")

    tagger.scope = .selection
    tagger.analyze()
    await tagger.finished()
    tagger.selectedID = 1
    controller.refresh()
    #expect(controller.combinedLine.isHidden)
    #expect(controller.text(controller.albumTable, .album, 0) == "Persuader – 1983")
    controller.window?.close()
}

/// Combine Albums for Tagging opens the tagger on the selection joined and analyzes it from
/// whichever source is chosen, the API too: the command is the click.
@MainActor
@Test func combineSelectionOpensOnTheAlbumsJoinedAndAnalyzesFromAnySource() async throws {
    for source in DiscogsSource.allCases {
        let seen = Seen()
        let tagger = DiscogsTagger(
            model: await model(
                seen, albums: [original, reissue], matches: matches, source: source))
        tagger.selectedTracks = { [100, 200] }
        tagger.combineSelection()
        #expect(tagger.model.scope == .combined)
        try await eventually { seen.matched.count == 1 }
        await tagger.model.finished()
        #expect(seen.sources == [source], "\(source)")
        #expect(tagger.model.albums.map(\.id) == [-1])
        tagger.window?.close()
    }
}

@MainActor
@Test func combineSelectionSaysWhyItCant() async throws {
    let gate = Gate()
    let seen = Seen()
    let tagger = DiscogsTagger(
        model: await model(seen, albums: [original, reissue], matches: matches, gate: gate))
    tagger.selectedTracks = { [100, 200] }
    tagger.show()
    try await eventually { tagger.model.isBusy }
    var failures: [String] = []
    tagger.model.failed = { message, _ in failures.append(message) }
    tagger.combineSelection()
    #expect(failures == ["The albums weren't combined"])
    #expect(tagger.model.scope == .selection)
    gate.open()
    gate.open()
    await tagger.model.finished()

    tagger.selectedTracks = { [] }
    tagger.combineSelection()
    #expect(failures.last == "No tracks are selected")

    let missing = DiscogsTagger(
        model: await model(
            Seen(), albums: [original, reissue], matches: matches, catalog: .missing))
    missing.selectedTracks = { [100, 200] }
    var missed: [(String, [String])] = []
    missing.combineSelection()
    // Set once the window is made, which sets its own; the analysis waits for the check.
    missing.model.failed = { missed.append(($0, $1)) }
    try await eventually { !missed.isEmpty }
    #expect(missed.first?.0 == "The combined album wasn't analyzed")
    #expect(missed.first?.1 == ["there's no Discogs catalog on this Mac"])
    tagger.window?.close()
    missing.window?.close()
}
