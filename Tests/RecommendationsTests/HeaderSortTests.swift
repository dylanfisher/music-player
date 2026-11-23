import AppKit
import Foundation
import Testing

@testable import Recommendations
@testable import Recommender

// Sorting by a header (ADR 0218): a discography's loaded rows by a column, the list's own
// order breaking ties and empty values last both ways; a paged list's headers don't sort.

private let gus = RecommendationQuery(seed: .discography(artistID: 23, name: "Gus Other"))

/// Album `id` from `year`, titled `title`, with `want` wants, or no values for nil.
private func row(_ id: Int, _ title: String, year: Int?, want: Int?) -> RecommendationRow {
    var made = album(id)
    made.title = title
    made.year = year
    made.community = want.map {
        CommunityValues(
            releaseID: made.releaseID ?? id, status: .fetched, checkedAt: nil,
            values: CommunityValues.Values(
                ratingAverage: Double($0) / 10, ratingCount: 1, have: 1, want: $0,
                numForSale: nil, lowestPrice: nil))
    }
    return RecommendationRow(album: made)
}

private let rows = [
    row(0, "album 10", year: 1999, want: 5),
    row(1, "Album 9", year: nil, want: 30),
    row(2, "Zebra", year: 2001, want: nil),
    row(3, "Aardvark", year: 1999, want: 5),
]

private func ids(_ column: RecommendationColumn, ascending: Bool) -> [Int] {
    RecommendationColumn.sorted(rows, by: HeaderSort(column: column, ascending: ascending))
        .map(\.album.id)
}

@Test func eachColumnSortsByItsValueEmptyLastAndTiesInTheListsOrder() {
    #expect(ids(.year, ascending: true) == [0, 3, 2, 1])
    #expect(ids(.year, ascending: false) == [2, 0, 3, 1], "empty last, ties kept, reversed")
    #expect(ids(.want, ascending: true) == [0, 3, 1, 2])
    #expect(ids(.want, ascending: false) == [1, 0, 3, 2])
    #expect(ids(.rating, ascending: false) == [1, 0, 3, 2], "by the average, not its text")
    #expect(ids(.title, ascending: true) == [3, 1, 0, 2], "numbers in a title as numbers")
    #expect(ids(.title, ascending: false) == [2, 0, 1, 3])
    #expect(ids(.forSale, ascending: true) == [0, 1, 2, 3], "every value empty")
    #expect(ids(.label, ascending: false) == [0, 1, 2, 3])
}

@Test func aReleaseNobodyRatedSortsAsEmpty() {
    var unrated = row(0, "Unrated", year: nil, want: 0)
    unrated.album.community?.values?.ratingCount = 0
    let sorted = { (ascending: Bool) in
        RecommendationColumn.sorted(
            [unrated, row(1, "None", year: nil, want: nil), row(2, "Rated", year: nil, want: 10)],
            by: HeaderSort(column: .rating, ascending: ascending)
        ).map(\.album.id)
    }
    #expect(sorted(true) == [2, 0, 1])
    #expect(sorted(false) == [2, 0, 1])
}

@Test func onlyADiscographysHeadersSortAndNeverDownload() {
    #expect(RecommendationColumn.allCases.filter { $0.sorts(RecommendationQuery()) }.isEmpty)
    let sorting = RecommendationColumn.allCases.filter { $0.sorts(gus) }
    #expect(sorting.contains(.year) && sorting.contains(.inLibrary))
    #expect(!sorting.contains(.download))
    #expect(!sorting.contains(.score), "a column the list doesn't show")
}

/// A discography of `total` albums whose years run down from 2100, served 100 at a time.
private func discography(_ total: Int, _ requests: Requests) -> RecommendationsService {
    var service = RecommendationsService.unused
    service.page = { query, offset, limit in
        requests.append(query, offset, limit)
        let end = min(total, offset + limit)
        var page = page(offset..<end, more: end < total)
        page.albums = page.albums?.map {
            var album = $0
            album.year = 2100 - $0.id
            return album
        }
        return page
    }
    return service
}

@MainActor
@Test func aSortReadsTheWholeListAndARefreshAndAReturnKeepIt() async {
    let requests = Requests()
    let service = discography(150, requests)
    let model = RecommendationsModel(service: { service })
    await model.show(gus)?.value
    #expect(model.rows.count == 100 && model.more)

    await model.sort(by: HeaderSort(column: .year, ascending: true))?.value
    #expect(requests.offsets == [0, 100], "the page not read yet")
    #expect(model.rows.count == 150 && !model.more)
    #expect(model.rows.first?.album.id == 149)
    #expect(model.headerSort == HeaderSort(column: .year, ascending: true))

    await model.readAgain(through: 0)?.value
    #expect(requests.offsets == [0, 100, 0, 100], "a refresh reads it whole too")
    #expect(model.rows.first?.album.id == 149)

    await model.show(RecommendationQuery())?.value
    #expect(model.headerSort == nil)
    #expect(model.rows.first?.album.id == 0, "the library's list in the service's order")
    await model.show(gus)?.value
    #expect(model.headerSort == HeaderSort(column: .year, ascending: true))
    #expect(model.rows.count == 150 && model.rows.first?.album.id == 149)

    var byTitle = model.query
    byTitle.sort = .title
    await model.show(byTitle)?.value
    #expect(model.headerSort == nil, "an order from the pop-up is the one shown")
    #expect(model.rows.first?.album.id == 0)
}

/// A discography whose first page of 100 says more follow and whose next pages are empty, which
/// throws after three asks so a read that keeps asking ends.
private func emptyAfterAPage(_ requests: Requests) -> RecommendationsService {
    var service = RecommendationsService.unused
    service.page = { query, offset, limit throws(RecommenderError) in
        requests.append(query, offset, limit)
        guard requests.offsets.count <= 3 else { throw unexpected("a page asked again") }
        var page = page(offset == 0 ? 0..<100 : 0..<0, more: true)
        page.albums = page.albums?.map {
            var album = $0
            album.inLibrary = true
            return album
        }
        return page
    }
    return service
}

@MainActor
@Test func anEmptyPageThatSaysMoreFollowStopsTheReadAndSaysSo() async {
    let requests = Requests()
    let service = emptyAfterAPage(requests)
    let model = RecommendationsModel(service: { service })
    await model.show(gus)?.value
    await model.sort(by: HeaderSort(column: .year, ascending: true))?.value
    #expect(requests.offsets == [0, 100])
    #expect(model.problem == .failed(RecommendationsModel.emptyPage(at: 100)))

    // Missing hides every row of the first page, so it reads on for rows to show.
    let missing = Requests()
    let filtered = emptyAfterAPage(missing)
    let other = RecommendationsModel(service: { filtered })
    var query = gus
    query.filters.missing = true
    let first = other.show(query)
    await first?.value
    for _ in 0..<5 {
        guard let next = other.reading else { break }
        await next.value
    }
    #expect(missing.offsets == [0, 100])
    #expect(other.problem == .failed(RecommendationsModel.emptyPage(at: 100)))
}

@MainActor
@Test func theWindowSortsByTheHeaderClickedAndShowsTheModelsSort() throws {
    let window = RecommendationsWindow()
    var chosen: [HeaderSort?] = []
    window.headerSortChosen = { chosen.append($0) }
    let year = try #require(
        window.table.tableColumns.first {
            $0.identifier.rawValue == RecommendationColumn.year.rawValue
        })
    let download = try #require(
        window.table.tableColumns.first {
            $0.identifier.rawValue == RecommendationColumn.download.rawValue
        })
    window.show(
        rows: rows, query: RecommendationQuery(), seeds: [.library], pending: false,
        message: nil, action: nil, facts: nil, headerSort: nil)
    #expect(year.sortDescriptorPrototype == nil, "a paged list's headers don't sort")

    window.show(
        rows: rows, query: gus, seeds: [.library, gus.seed], pending: false, message: nil,
        action: nil, facts: nil, headerSort: nil)
    #expect(year.sortDescriptorPrototype != nil)
    #expect(download.sortDescriptorPrototype == nil)
    window.table.selectRowIndexes([1, 2], byExtendingSelection: false)
    window.table.sortDescriptors = [NSSortDescriptor(key: "year", ascending: false)]
    #expect(chosen == [HeaderSort(column: .year, ascending: false)])

    let sorted = RecommendationColumn.sorted(rows, by: HeaderSort(column: .year, ascending: false))
    window.show(
        rows: sorted, query: gus, seeds: [.library, gus.seed], pending: false, message: nil,
        action: nil, facts: nil, headerSort: HeaderSort(column: .year, ascending: false))
    #expect(chosen.count == 1, "the model's sort isn't heard as a click")
    #expect(window.selectedRows.map(\.album.id) == [2, 1], "the selection follows its rows")

    window.show(
        rows: rows, query: gus, seeds: [.library, gus.seed], pending: false, message: nil,
        action: nil, facts: nil, headerSort: nil)
    #expect(window.table.sortDescriptors.isEmpty)
    #expect(chosen.count == 1)
    window.window?.close()
}
