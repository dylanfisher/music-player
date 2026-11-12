import AppKit
import Testing

@testable import Recommendations
@testable import Recommender

// The Download column: the state of the newest job of each row's release, as Downloads says.

@MainActor
@Test func theDownloadColumnShowsEachReleasesJob() throws {
    let window = RecommendationsWindow()
    var masterless = album(9)
    masterless.releaseID = nil
    window.show(
        rows: [album(7), album(8), masterless].map { RecommendationRow(album: $0) },
        query: RecommendationQuery(), seeds: [], pending: false, message: nil, action: nil,
        facts: nil)
    let column = try #require(
        window.table.tableColumns.first {
            $0.identifier.rawValue == RecommendationColumn.download.rawValue
        })
    let shown = {
        (0..<3).map {
            (window.tableView(window.table, viewFor: column, row: $0) as? NSTextField)?
                .stringValue
        }
    }
    #expect(shown() == ["", "", ""])
    window.show(downloads: [1007: "Queued", 1009: "Staged"])
    #expect(shown() == ["Queued", "", ""])
}
