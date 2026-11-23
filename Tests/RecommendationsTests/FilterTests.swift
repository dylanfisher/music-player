import AppKit
import Testing

@testable import DisplayText
@testable import Recommendations
@testable import Recommender

// The search field: the rows read so far, filtered by every word typed, with the query left as
// it was.

/// Album 1 by Björk on One Little Indian, a Trip Hop album 2 and album 3 as `album` makes them.
private func rows() -> [RecommendationRow] {
    var bjork = album(1)
    bjork.artists = [RecommendationPage.Named(id: 2, name: "Björk")]
    bjork.title = "Homogenic"
    bjork.year = 1997
    bjork.label = RecommendationPage.Named(id: 3, name: "One Little Indian")
    var tripHop = album(2)
    tripHop.styles = [RecommendationPage.Named(id: 4, name: "Trip Hop")]
    return [bjork, tripHop, album(3)].map { RecommendationRow(album: $0) }
}

@Test func theFilterMatchesAWordInAnyColumnItShows() {
    let columns: [RecommendationColumn] = [.artist, .title, .year, .label, .styles, .download]
    func ids(_ text: String) -> [Int] {
        RecommendationsModel.filtered(
            rows(), by: ListFilter(text), columns: columns, downloads: [1003: "Downloading"]
        ).map(\.album.id)
    }
    #expect(ids("bjork") == [1], "the artist, without the accent")
    #expect(ids("homogenic") == [1], "the title")
    #expect(ids("1997") == [1], "the year")
    #expect(ids("indian") == [1], "the label")
    #expect(ids("trip") == [2], "a style")
    #expect(ids("downloading") == [3], "the Download column")
    #expect(ids("made-up 2001") == [2, 3], "two words in two columns")
    #expect(ids("bjork trip").isEmpty, "every word, in one row")
    #expect(ids("") == [1, 2, 3])
}

@MainActor
private func show(_ rows: [RecommendationRow], in window: RecommendationsWindow) {
    window.show(
        rows: rows, query: RecommendationQuery(), seeds: [.library], pending: false,
        message: nil, action: nil, facts: nil, headerSort: nil)
}

@MainActor
private func type(_ text: String, in window: RecommendationsWindow) {
    window.search.stringValue = text
    window.controlTextDidChange(
        Notification(name: NSControl.textDidChangeNotification, object: window.search))
}

@MainActor
@Test func theSearchFieldFiltersTheRowsReadAndAReadKeepsIt() throws {
    let window = RecommendationsWindow()
    var queries: [RecommendationQuery] = []
    window.queryChosen = { queries.append($0) }
    var ends = 0
    window.reachedEnd = { ends += 1 }
    show(rows(), in: window)
    type("made-up", in: window)
    #expect(window.rows.map(\.album.id) == [2, 3])
    #expect(queries.isEmpty, "the service's query is left as it was")
    _ = window.tableView(window.table, viewFor: window.table.tableColumns[1], row: 1)
    #expect(ends == 0, "a filtered list reads no more")
    show(rows() + [RecommendationRow(album: album(4))], in: window)
    #expect(window.rows.map(\.album.id) == [2, 3, 4], "the rows of a read are filtered too")
    #expect(window.messageLabel.isHidden)
    type("zzz", in: window)
    #expect(window.rows.isEmpty)
    #expect(!window.messageLabel.isHidden)
    #expect(window.messageLabel.stringValue == RecommendationsWindow.noneMatch)
    type("", in: window)
    #expect(window.rows.count == 4)
    #expect(window.messageLabel.isHidden)
    type("zzz", in: window)
    // The cancel button: the field emptied and its action sent, with no text change.
    window.search.stringValue = ""
    window.search.sendAction(window.search.action, to: window.search.target)
    #expect(window.rows.count == 4, "cleared by the cancel button")
    window.show(downloads: [1004: "Queued"], imported: [:])
    type("queued", in: window)
    #expect(window.rows.map(\.album.id) == [4], "the Download column")
    window.window?.close()
}
