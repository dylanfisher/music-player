import Foundation
import Library
import Testing

@testable import Discogs
@testable import DiscogsTagger
@testable import Settings

private let stockholm = ["Östermalm", "Gamla Stan", "Kungsholmen"]
private let one = album(1, "Stockholm", titles: stockholm)
private let exact: @Sendable (DiscogsAlbum, Int?) -> AlbumMatch = { album, _ in
    match(album, release(10, "Stockholm", titles: stockholm), tier: .exact)
}

@MainActor
@Test func everySourceCanBePickedAndWithoutATokenTheAPISaysWhatStillWorks() async throws {
    for (catalog, token) in [
        (readyCatalog, true), (readyCatalog, false), (TaggerModel.CatalogState.missing, true),
        (.missing, false),
    ] {
        let tagger = await model(Seen(), albums: [one], matches: exact, catalog: catalog)
        tagger.hasToken = { token }
        let window = TaggerWindow(model: tagger)
        let items = window.sourcePopUp.itemArray
        #expect(items.map(\.title) == ["Local Catalog", "Discogs API", "Both"])
        #expect(items.allSatisfy { $0.isEnabled }, "\(catalog) \(token)")
        #expect(items[0].toolTip == nil)
        for item in items.dropFirst() {
            #expect(item.toolTip == (token ? nil : TaggerWindow.noTokenTip), "\(token)")
        }
        #expect(TaggerWindow.noTokenTip.contains("only releases already tagged with an ID"))
        window.window?.close()
    }
}

@MainActor
@Test func theSourceIsSavedAndRestoredAndDefaultsByTheCatalog() async throws {
    // None saved: the catalog when there is one, else the API.
    let withCatalog = await model(Seen(), albums: [], matches: exact, source: nil)
    #expect(withCatalog.source == .catalog)
    let without = await model(Seen(), albums: [], matches: exact, catalog: .missing, source: nil)
    #expect(without.source == .api)
    // A saved one is kept, catalog or not.
    let restored = await model(
        Seen(), albums: [], matches: exact, catalog: .missing, source: .both)
    #expect(restored.source == .both)
    var saved: [DiscogsSource] = []
    restored.sourceSaved = { saved.append($0) }
    let window = TaggerWindow(model: restored)
    #expect(window.sourcePopUp.indexOfSelectedItem == 2)
    window.sourcePopUp.selectItem(at: 1)
    _ = window.sourcePopUp.target?.perform(window.sourcePopUp.action, with: window.sourcePopUp)
    #expect(restored.source == .api)
    #expect(saved == [.api])
    window.window?.close()
}

@MainActor
@Test func withoutACatalogTheAPIAnalyzesAndBothSaysItAskedTheAPIAlone() async throws {
    let seen = Seen()
    let tagger = await model(
        seen, albums: [one], matches: exact, catalog: .missing, source: .catalog)
    #expect(!tagger.canAnalyze)
    tagger.chooseSource(.api)
    #expect(tagger.canAnalyze)
    tagger.analyze()
    await tagger.finished()
    #expect(seen.sources == [.api])
    #expect(!tagger.status.contains("alone"))
    tagger.chooseSource(.both)
    #expect(tagger.canAnalyze)
    tagger.analyze()
    await tagger.finished()
    #expect(seen.sources == [.api, .api])
    #expect(tagger.status.contains("with no catalog, Both asked the Discogs API alone"))
    // With a catalog, Both is Both.
    let withCatalog = Seen()
    let both = await model(withCatalog, albums: [one], matches: exact, source: .both)
    both.analyze()
    await both.finished()
    #expect(withCatalog.sources == [.both])
}

@MainActor
@Test func aDiscogsErrorThatStopsTheRunIsOneAlertAndTheAlbumsStay() async throws {
    for (error, message) in [
        (DiscogsAPIError.unauthorized, "The Discogs token was refused"),
        (.offline, "There is no connection to Discogs"),
    ] {
        let seen = Seen()
        let tagger = await model(
            seen, albums: [one], matches: exact, source: .api, matchError: error)
        var alerts: [(String, [String])] = []
        tagger.failed = { alerts.append(($0, $1)) }
        tagger.analyze()
        await tagger.finished()
        #expect(alerts.map(\.0) == [message])
        #expect(tagger.albums.isEmpty, "the last run's, of which there was none")
        #expect(tagger.status.hasPrefix("Analyze stopped"))
        #expect(!tagger.status.contains(fakeTokenText))
    }
}

/// Made up; the window's text must never hold a token, and none is ever given it.
private let fakeTokenText = "fakeTOKENfor3tests0nly"

@MainActor
@Test func theAPISourceNeverAnalyzesWithoutAClick() async throws {
    for source in [DiscogsSource.api, .both] {
        let seen = Seen()
        let tagger = DiscogsTagger(
            model: await model(seen, albums: [one], matches: exact, source: source))
        tagger.selectedTracks = { [100] }
        tagger.show()
        #expect(tagger.model.scope == .selection)
        try await eventually { tagger.model.catalog != .checking }
        try await Task.sleep(nanoseconds: 200_000_000)
        await tagger.model.finished()
        #expect(seen.matched.isEmpty, "\(source)")
        tagger.window?.close()
    }
}

@MainActor
@Test func theStatusLineCountsTheAPIsAlbumsApartAndSaysItWaits() async throws {
    let gate = Gate()
    let tagger = TaggerModel(
        effects: .init(
            albums: { [one] }, reviews: { [:] }, review: { _, _ in },
            match: { albums, _, _, _, report in
                report(
                    AlbumMatchProgress(
                        albumsDone: 412, albumCount: 412, apiAlbumsDone: 3, apiAlbumCount: 17,
                        waitingSeconds: 40))
                gate.wait()
                return albums.map { exact($0, nil) }
            }, choose: { _, previous, _, _ in previous }, summaries: { _ in [] },
            release: { _ in nil },
            read: { _, _ in ([], []) }, checkCatalog: { readyCatalog },
            unfinishedImport: { nil },
            importCatalog: { _, _, _ in throw CatalogImportError.stopped }),
        mapping: DiscogsPreset.minimal.mapping, savedMappings: [], choices: defaultChoices,
        source: .both)
    await tagger.checkCatalog()
    let window = TaggerWindow(model: tagger)
    tagger.analyze()
    try await eventually { tagger.matchProgress?.apiAlbumCount == 17 }
    #expect(
        window.statusLabel.stringValue
            == "Catalog 412 of 412, then Discogs 3 of 17; waiting 40 s for Discogs's rate limit")
    gate.open()
    await tagger.finished()
    window.window?.close()
}

@MainActor
@Test func aReleaseFromTheAPISaysSoUnderItsTitle() async throws {
    let tagger = await model(
        Seen(), albums: [one],
        matches: { album, _ in
            var found = match(album, release(10, "Stockholm", titles: stockholm), tier: .exact)
            found.origin = .api
            return found
        }, source: .api)
    tagger.analyze()
    await tagger.finished()
    let window = TaggerWindow(model: tagger)
    #expect(window.releaseLine.stringValue.hasSuffix("from the Discogs API"))
    window.window?.close()
}

@MainActor
@Test func whenTheAPIStopsBothTheCatalogsMatchesAreShownWithTheAlert() async throws {
    let stopped = APIStoppedMatching(matches: [exact(one, nil)], error: .offline)
    let tagger = await model(
        Seen(), albums: [one], matches: exact, source: .both, matchError: stopped)
    var alerts: [String] = []
    tagger.failed = { message, _ in alerts.append(message) }
    tagger.analyze()
    await tagger.finished()
    #expect(alerts == ["There is no connection to Discogs"])
    #expect(tagger.albums.map(\.id) == [1])
    #expect(tagger.status.contains("Discogs stopped"))
}
