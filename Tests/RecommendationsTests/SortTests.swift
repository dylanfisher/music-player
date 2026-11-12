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
