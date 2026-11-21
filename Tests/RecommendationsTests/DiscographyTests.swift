import AppKit
import Discogs
import Foundation
import Testing

@testable import Recommendations
@testable import Recommender

// Show Discography: from a track's release, a row's artists or a pasted id, each artist once
// and never Various Artists.

private let gus = RecommendationPage.Named(id: 23, name: "Gus Other")
private let dee = RecommendationPage.Named(id: 21, name: "Dee Producer")
private let various = RecommendationPage.Named(id: 194, name: "Various")

/// Catalog reads that know release 10, by Gus and Dee, master 100, by Gus, and nothing else.
private func catalogReads() -> DiscographyArtists {
    DiscographyArtists(
        release: { $0 == 10 ? [gus, various, dee, gus] : nil },
        master: { $0 == 100 ? [gus] : nil },
        name: { $0 == 23 ? "Gus Other" : nil })
}

private struct Unreadable: Error, CustomStringConvertible {
    var description: String { "made-up failure" }
}

@Test func aTracksReleaseOffersItsMainArtistsOrSaysWhyNot() {
    #expect(DiscographyChoice.of(release: 10, catalogReads().release) == .artists([gus, dee]))
    #expect(
        DiscographyChoice.of(release: nil, catalogReads().release)
            == .unavailable(DiscographyChoice.noReleaseText))
    #expect(
        DiscographyChoice.of(release: 11, catalogReads().release)
            == .unavailable("This Mac's Discogs catalog doesn't have release 11"))
    #expect(
        DiscographyChoice.of(release: 10) { _ in [various] }
            == .unavailable("Various Artists has no discography"))
    #expect(
        DiscographyChoice.of(release: 10) { _ in throw Unreadable() }
            == .unavailable("Couldn't read the Discogs catalog: made-up failure"))
}

@Test func aRowOffersTheArtistsItCarries() {
    var row = album(7)
    row.artists = [various, dee]
    #expect(DiscographyChoice(row) == .artists([dee]))
    row.artists = [various]
    #expect(DiscographyChoice(row) == .unavailable(DiscographyChoice.variousArtistsText))
    row.artists = []
    #expect(DiscographyChoice(row) == .unavailable("No main artist is linked to a Discogs artist"))
}

@Test func aPastedIdOffersItsArtistOrItsMainArtists() {
    #expect(DiscographyChoice.of(.artist(23), catalogReads()) == .artists([gus]))
    #expect(
        DiscographyChoice.of(.artist(99), catalogReads())
            == .artists([RecommendationPage.Named(id: 99, name: nil)]))
    #expect(
        DiscographyChoice.of(.artist(194), catalogReads())
            == .unavailable("Various Artists has no discography"))
    #expect(DiscographyChoice.of(.release(10), catalogReads()) == .artists([gus, dee]))
    #expect(DiscographyChoice.of(.master(100), catalogReads()) == .artists([gus]))
    #expect(
        DiscographyChoice.of(.master(101), catalogReads())
            == .unavailable("This Mac's Discogs catalog doesn't have master 101"))
}

@Test func withoutACatalogAPastedArtistStillOpensAndAReleaseSaysWhy() {
    let reads = DiscographyArtists(catalogAt: nil)
    #expect(
        DiscographyChoice.of(.artist(23), reads)
            == .artists([RecommendationPage.Named(id: 23, name: nil)]))
    #expect(
        DiscographyChoice.of(.release(10), reads)
            == .unavailable(
                "Couldn't read the Discogs catalog: no place is set for this Mac's Discogs catalog")
    )
}

@MainActor
@Test func theItemOpensOneArtistListsSeveralOrIsDisabledWithTheReason() throws {
    let items = DiscographyItems()
    var opened: [RecommendationPage.Named] = []
    items.open = { opened.append($0) }
    let item = NSMenuItem(title: "Show Discography", action: nil, keyEquivalent: "")

    items.fill(item, .artists([gus, dee]))
    let submenu = item.submenu
    #expect(submenu?.items.map(\.title) == ["Gus Other", "Dee Producer"])
    #expect(item.isEnabled)
    let second = try #require(submenu?.items.last)
    let action = try #require(second.action)
    NSApplication.shared.sendAction(action, to: second.target, from: second)

    items.fill(item, .artists([RecommendationPage.Named(id: 99, name: nil)]))
    #expect(item.submenu == nil && item.action != nil && item.toolTip == "Discogs artist 99")
    NSApplication.shared.sendAction(try #require(item.action), to: item.target, from: item)
    #expect(opened.map(\.id) == [21, 99])

    items.fill(item, .unavailable(DiscographyChoice.noReleaseText))
    #expect(item.submenu == nil && item.action == nil && !item.isEnabled)
    #expect(item.toolTip == DiscographyChoice.noReleaseText)
}

@MainActor
@Test func aPastedIdShowsItsDiscographyInThePopUpOrSaysWhyNot() async throws {
    let recommendations = Recommendations(
        databaseURL: URL(fileURLWithPath: "/dev/null", isDirectory: false))
    let requests = Requests()
    recommendations.service = { list(3, requests) }
    recommendations.readDiscographyArtists = { pasted, _ in
        DiscographyChoice.of(pasted, catalogReads())
    }
    var beeps = 0
    recommendations.beep = { beeps += 1 }

    await recommendations.showDiscography(pasted: "https://www.discogs.com/fr/artist/23-Gus-Other")?
        .value
    let seed = RecommendationQuery.Seed.discography(artistID: 23, name: "Gus Other")
    #expect(recommendations.model.query.seed == seed && recommendations.model.query.sort == .year)
    #expect(recommendations.model.seeds == [.library, seed])
    await recommendations.model.show(recommendations.model.query)?.value
    #expect(requests.queries.last?.seed == seed)

    recommendations.showDiscography(gus)
    #expect(recommendations.model.seeds == [.library, seed])

    #expect(recommendations.showDiscography(pasted: "https://www.discogs.com/label/30") == nil)
    #expect(recommendations.model.notice?.hasPrefix("That isn't a Discogs artist") == true)
    await recommendations.showDiscography(pasted: "https://www.discogs.com/master/101")?.value
    #expect(recommendations.model.notice == "This Mac's Discogs catalog doesn't have master 101")
    #expect(beeps == 2)
    recommendations.controller?.close()
}

@MainActor
@Test func aTrackMenuGetsTheItemOnceAndFillsItForTheTrackAsItOpens() throws {
    let recommendations = Recommendations(
        databaseURL: URL(fileURLWithPath: "/dev/null", isDirectory: false))
    recommendations.discographyArtists = { catalogReads() }
    var release: Int? = 10
    let menu = NSMenu()
    menu.addItem(withTitle: "Play", action: nil, keyEquivalent: "")
    recommendations.showDiscography(in: menu) { release }
    #expect(menu.items.map(\.title) == ["Play", "", "Show Discography"])
    let delegate = try #require(menu.delegate)
    delegate.menuNeedsUpdate?(menu)
    let item = try #require(menu.item(withTitle: "Show Discography"))
    #expect(item.submenu?.items.map(\.title) == ["Gus Other", "Dee Producer"])
    release = nil
    delegate.menuNeedsUpdate?(menu)
    #expect(item.submenu == nil && !item.isEnabled)
    #expect(item.toolTip == DiscographyChoice.noReleaseText)

    let trackMenu = NSMenu()
    trackMenu.addItem(withTitle: "Show Discography", action: nil, keyEquivalent: "")
    recommendations.showDiscography(in: trackMenu) { 11 }
    trackMenu.delegate?.menuNeedsUpdate?(trackMenu)
    #expect(trackMenu.items.count == 1)
    #expect(trackMenu.items[0].toolTip == "This Mac's Discogs catalog doesn't have release 11")
    #expect(menu.delegate === delegate, "each menu keeps its own")
}

@MainActor
@Test func anotherWindowsRowGetsAnItemForItsRelease() {
    let recommendations = Recommendations(
        databaseURL: URL(fileURLWithPath: "/dev/null", isDirectory: false))
    recommendations.discographyArtists = { catalogReads() }
    let item = recommendations.discographyItem(release: 10)
    #expect(item.title == "Show Discography" && item.submenu?.items.count == 2)
    #expect(!recommendations.discographyItem(release: nil).isEnabled)
}
