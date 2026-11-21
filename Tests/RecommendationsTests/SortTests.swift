import AppKit
import Foundation
import Testing

@testable import Recommendations
@testable import Recommender

// The Sort pop-up: the albums' order, by score or by a community value; the Artists view has
// none.

@MainActor
@Test func theSortPopUpAsksForTheListInItsOrder() {
    let window = RecommendationsWindow()
    var chosen: [RecommendationQuery] = []
    window.queryChosen = { chosen.append($0) }
    window.show(
        rows: [], query: RecommendationQuery(), seeds: [.library], pending: false,
        message: nil, action: nil, facts: nil)
    #expect(window.sortButton.titleOfSelectedItem == "By Score")
    #expect(window.sortButton.itemTitles.last == "By Want per Have")
    window.sortButton.selectItem(withTitle: "By Rating")
    window.sortButton.sendAction(window.sortButton.action, to: window.sortButton.target)
    #expect(chosen.map(\.sort) == [.rating])

    window.show(
        rows: [], query: RecommendationQuery(sort: .want), seeds: [.library], pending: false,
        message: nil, action: nil, facts: nil)
    #expect(window.sortButton.titleOfSelectedItem == "By Want")
    window.show(
        rows: [], query: RecommendationQuery(show: .artists, sort: .want), seeds: [.library],
        pending: false, message: nil, action: nil, facts: nil)
    #expect(!window.sortButton.isEnabled)
}

@MainActor
@Test func aDiscographyOffersYearAndTitleAndNoScore() {
    let window = RecommendationsWindow()
    var chosen: [RecommendationQuery] = []
    window.queryChosen = { chosen.append($0) }
    let seed = RecommendationQuery.Seed.discography(artistID: 23, name: "Gus Other")
    window.show(
        rows: [], query: RecommendationQuery(seed: seed, sort: .year), seeds: [.library, seed],
        pending: false, message: nil, action: nil, facts: nil)
    #expect(
        window.sortButton.itemTitles == [
            "By Year", "By Title", "By Rating", "By Have", "By Want", "By Want per Have",
        ])
    #expect(window.sortButton.titleOfSelectedItem == "By Year")
    #expect(window.listButton.titleOfSelectedItem == "Discography: Gus Other")
    window.sortButton.selectItem(withTitle: "By Title")
    window.sortButton.sendAction(window.sortButton.action, to: window.sortButton.target)
    #expect(chosen.map(\.sort) == [.title])

    window.show(
        rows: [], query: RecommendationQuery(), seeds: [.library, seed], pending: false,
        message: nil, action: nil, facts: nil)
    #expect(window.sortButton.itemTitles.first == "By Score")
    #expect(!window.sortButton.itemTitles.contains("By Year"))
}

@MainActor
@Test func twoDiscographiesNamedAlikeAreTwoItemsInTheListPopUp() {
    let window = RecommendationsWindow()
    var chosen: [RecommendationQuery] = []
    window.queryChosen = { chosen.append($0) }
    let first = RecommendationQuery.Seed.discography(artistID: 23, name: "Gus Other")
    let second = RecommendationQuery.Seed.discography(artistID: 4242, name: "Gus Other")
    window.show(
        rows: [], query: RecommendationQuery(seed: second), seeds: [.library, first, second],
        pending: false, message: nil, action: nil, facts: nil)
    #expect(window.listButton.numberOfItems == 3)
    #expect(window.listButton.indexOfSelectedItem == 2)
    window.listButton.selectItem(at: 1)
    window.listButton.sendAction(window.listButton.action, to: window.listButton.target)
    #expect(chosen.map(\.seed) == [first])
}

@MainActor
@Test func everyTitleIsAnItemOfAPopUpInOrder() {
    let popUp = NSPopUpButton()
    popUp.addEveryItem(withTitles: ["Gus", "Dee", "Gus"])
    #expect(popUp.itemTitles == ["Gus", "Dee", "Gus"])
    #expect(popUp.indexOfSelectedItem == 0)
}

@MainActor
@Test func movingBetweenADiscographyAndAScoredListTakesEachOnesOrder() async {
    let requests = Requests()
    let model = RecommendationsModel(service: { list(10, requests) })
    let seed = RecommendationQuery.Seed.discography(artistID: 23, name: "Gus Other")
    await model.show(RecommendationQuery(seed: seed, show: .artists))?.value
    #expect(model.query.sort == .year && model.query.show == .albums)
    var query = model.query
    query.seed = .library
    await model.show(query)?.value
    #expect(model.query.sort == .score)
    #expect(requests.queries.map(\.sort) == [.year, .score])
}

@Test func aDiscographysRefusalsSayWhatTheServiceSaid() {
    let seed = RecommendationQuery.Seed.discography(artistID: 4242, name: "Made-Up")
    #expect(
        problemText(.unknownArtist, seed: seed)
            == "Discogs has no artist 4242 in this Mac's catalog")
    #expect(problemText(.variousArtists, seed: seed) == "Various Artists has no discography")
}

@MainActor
@Test func anUnknownArtistAndVariousArtistsAreTheirProblems() async {
    for (kind, expected) in [
        (RecommenderError.Kind.status(404, code: "unknown_artist"), ListProblem.unknownArtist),
        (.badRequest(code: "various_artists", message: "no"), .variousArtists),
    ] {
        var service = RecommendationsService.unused
        service.page = { _, _, _ throws(RecommenderError) in
            throw RecommenderError(service: "the fake", kind: kind)
        }
        let model = RecommendationsModel(service: { service })
        await model.show(
            RecommendationQuery(seed: .discography(artistID: 194, name: "Various")))?.value
        #expect(model.problem == expected)
    }
}
