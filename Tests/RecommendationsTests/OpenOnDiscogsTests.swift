import AppKit
import Foundation
import Testing

@testable import Recommendations
@testable import Recommender

// Open on Discogs: the button opens the first selected album's page, its master's or, for a
// release without one, its release's.

@MainActor
@Test func openOnDiscogsOpensTheFirstSelectedAlbumsPage() {
    let window = RecommendationsWindow()
    var release = album(8)
    release.kind = .release
    window.show(
        rows: [album(7), release].map { RecommendationRow(album: $0) },
        query: RecommendationQuery(), seeds: [], pending: false, message: nil, action: nil,
        facts: nil)
    var opened: [URL] = []
    window.discogsChosen = { opened.append(discogsPage(of: $0.album)) }
    #expect(!window.discogsButton.isEnabled)
    window.table.selectRowIndexes([1, 0], byExtendingSelection: false)
    #expect(window.discogsButton.isEnabled)
    window.discogsButton.performClick(nil)
    window.table.selectRowIndexes([1], byExtendingSelection: false)
    window.discogsButton.performClick(nil)
    let addresses = ["https://www.discogs.com/master/7", "https://www.discogs.com/release/8"]
    #expect(opened.map(\.absoluteString) == addresses)
}
