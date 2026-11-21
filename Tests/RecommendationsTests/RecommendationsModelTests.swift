import AppKit
import Foundation
import Testing

@testable import Recommendations
@testable import Recommender

@MainActor
@Test func theListIsReadAPageAtATimeWhileThereIsMore() async {
    let requests = Requests()
    let model = RecommendationsModel(service: { list(250, requests) })
    await model.show(RecommendationQuery())?.value
    #expect(model.rows.count == 100 && model.more)
    #expect(model.facts == facts)
    await model.readMore()?.value
    await model.readMore()?.value
    #expect(model.rows.map(\.album.id) == Array(0..<250))
    #expect(!model.more)
    #expect(model.readMore() == nil)
    #expect(requests.offsets == [0, 100, 200])
}

@MainActor
@Test func aChangeOfFilterReadsFromTheFirstRow() async {
    let requests = Requests()
    let model = RecommendationsModel(service: { list(250, requests) })
    await model.show(RecommendationQuery())?.value
    await model.readMore()?.value
    var query = RecommendationQuery()
    query.filters.styles = ["Deep House"]
    await model.show(query)?.value
    #expect(requests.offsets == [0, 100, 0])
    #expect(requests.queries.last == query)
    #expect(model.rows.map(\.album.id) == Array(0..<100))
}

@MainActor
@Test func aBusyServiceIsAskedAgainSixTimesThenGivenUpOn() async {
    let requests = Requests()
    let sleeps = Sleeps()
    var service = RecommendationsService.unused
    service.page = { query, offset, limit throws(RecommenderError) in
        requests.append(query, offset, limit)
        throw RecommenderError(service: "the fake", kind: .status(503, code: "busy"))
    }
    let model = RecommendationsModel(service: { service }, sleep: sleeps.sleep)
    await model.show(RecommendationQuery())?.value
    #expect(requests.offsets.count == 7)
    #expect(sleeps.seconds == Array(repeating: 5, count: 6))
    #expect(model.problem == .busy)
    #expect(!model.isReading)
}

@MainActor
@Test func aListBeingScoredAgainIsAskedForAgainUntilItIsThere() async {
    let requests = Requests()
    let sleeps = Sleeps()
    let full = list(10, requests)
    var service = RecommendationsService.unused
    service.page = { query, offset, limit throws(RecommenderError) in
        guard requests.offsets.count >= 2 else {
            requests.append(query, offset, limit)
            var refusal = ServiceRefusal(code: .outOfDate, message: "x")
            refusal.rebuilding = true
            throw RecommenderError(service: "the fake", kind: .refused(refusal))
        }
        return try await full.page(query, offset, limit)
    }
    let model = RecommendationsModel(service: { service }, sleep: sleeps.sleep)
    await model.show(RecommendationQuery())?.value
    #expect(sleeps.seconds == [30, 30])
    #expect(model.rows.count == 10)
    #expect(model.problem == nil)
}

@MainActor
@Test func aMarkTakesItsRowsOutThenReadsTheRowsShownAgain() async {
    let requests = Requests()
    let calls = MarkCalls()
    var service = list(250, requests)
    service.mark = { kind, id, verdict in
        calls.append("\(kind) \(id)")
        return FeedbackMark(seq: 1, kind: kind, id: id, verdict: verdict, at: 0)
    }
    let model = RecommendationsModel(service: { service })
    await model.show(RecommendationQuery())?.value
    await model.readMore()?.value
    let marking = model.mark([model.rows[5], model.rows[7]], .notInterested)
    #expect(model.rows.count == 198)
    #expect(!model.rows.contains { [5, 7].contains($0.album.id) })
    let marked = await marking?.value
    #expect(marked == [MarkedAlbum(kind: .master, id: 5), MarkedAlbum(kind: .master, id: 7)])
    #expect(calls.calls == ["master 5", "master 7"])
    #expect(requests.offsets == [0, 100, 0, 100])
    #expect(model.notice == nil)
}

@MainActor
@Test func undoRemovesTheMarksAndReadsTheListAgain() async {
    let requests = Requests()
    let calls = MarkCalls()
    var service = list(250, requests)
    service.unmark = { kind, id in
        calls.append("\(kind) \(id)")
        return true
    }
    let model = RecommendationsModel(service: { service })
    await model.show(RecommendationQuery())?.value
    await model.unmark([MarkedAlbum(kind: .release, id: 42)])?.value
    #expect(calls.calls == ["release 42"])
    #expect(requests.offsets == [0, 0, 100])
    #expect(model.rows.count == 200)
}

@MainActor
@Test func aFailedMarkPutsItsRowsBackAndSaysWhy() async {
    let requests = Requests()
    var service = list(10, requests)
    service.mark = { _, _, _ throws(RecommenderError) in
        throw RecommenderError(service: "the fake", kind: .status(500, code: "internal"))
    }
    let model = RecommendationsModel(service: { service })
    await model.show(RecommendationQuery())?.value
    let before = model.rows
    service.page = { _, _, _ throws(RecommenderError) in
        throw RecommenderError(service: "the fake", kind: .status(500, code: "internal"))
    }
    let marked = await model.mark([model.rows[3]], .alreadyHave)?.value
    #expect(marked == [])
    #expect(model.rows == before)
    #expect(model.notice?.hasPrefix("Couldn't mark the album") == true)
}

// A discography: Missing filters the rows read, and the list is read again while its values
// come in.

private let discography = RecommendationQuery(
    seed: .discography(artistID: 23, name: "Gus Other"), sort: .rating)

/// A discography of `total` albums, the even ones in the library, that answers each request
/// with the next of `pending`, then 0.
private func discographyList(_ total: Int, _ requests: Requests, pending: [Int])
    -> RecommendationsService
{
    let answers = Answers(pending)
    var service = RecommendationsService.unused
    service.page = { query, offset, limit in
        requests.append(query, offset, limit)
        let end = min(total, offset + limit)
        var page = page(offset..<end, more: end < total)
        page.albums = page.albums?.map {
            var album = $0
            album.inLibrary = album.id % 2 == 0
            return album
        }
        page.pending = answers.next()
        return page
    }
    return service
}

/// Answers given in order, then 0.
private final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var left: [Int]

    init(_ answers: [Int]) { left = answers }

    func next() -> Int { lock.withLock { left.isEmpty ? 0 : left.removeFirst() } }
}

@MainActor
@Test func missingHidesADiscographysOwnedAlbumsWithoutAskingAgain() async {
    let requests = Requests()
    let model = RecommendationsModel(service: { discographyList(6, requests, pending: []) })
    await model.show(discography)?.value
    #expect(model.rows.map(\.album.id) == [0, 1, 2, 3, 4, 5])
    var missing = model.query
    missing.filters.missing = true
    #expect(model.show(missing) == nil)
    #expect(model.rows.map(\.album.id) == [1, 3, 5])
    #expect(model.query.filters.missing)
    missing.filters.missing = false
    #expect(model.show(missing) == nil)
    #expect(model.rows.count == 6)
    #expect(requests.offsets == [0])

    var library = RecommendationQuery()
    library.filters.missing = true
    await model.show(library)?.value
    #expect(requests.queries.last?.filters.missing == true)
    #expect(model.rows.count == 6)
}

@MainActor
@Test func aDiscographyIsReadAgainEvery15SecondsWhilePendingIsOver0() async {
    let requests = Requests()
    let sleeps = Sleeps()
    let service = discographyList(150, requests, pending: [7, 3])
    let model = RecommendationsModel(service: { service }, sleep: sleeps.sleep)
    await model.show(discography)?.value
    #expect(model.pending == 7)
    for _ in 0..<10 {
        guard let next = model.refreshing ?? model.reading else { break }
        await next.value
    }
    #expect(model.refreshing == nil && !model.isReading)
    #expect(model.pending == 0)
    #expect(sleeps.seconds == [15, 15])
    #expect(requests.offsets == [0, 0, 0])
    #expect(model.rows.count == 100 && model.more)
}

@MainActor
@Test func askingAgainStopsWhenTheListChangesOrTheWindowCloses() async {
    let requests = Requests()
    let service = discographyList(5, requests, pending: [4, 4, 4])
    let model = RecommendationsModel(
        service: { service }, sleep: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) })
    await model.show(discography)?.value
    let waiting = model.refreshing
    #expect(waiting != nil)
    model.stop()
    await waiting?.value
    #expect(model.refreshing == nil)
    model.resume()
    let resumed = model.refreshing
    #expect(resumed != nil)
    var library = RecommendationQuery()
    library.filters.styles = ["Deep House"]
    model.show(library)
    await resumed?.value
    #expect(requests.queries.map(\.seed.isDiscography) == [true, false])
    model.stop()
}

@Test func aSelectionFollowsItsAlbumsAsTheRowsReorder() {
    let rows = [album(3), album(1), album(2)].map { RecommendationRow(album: $0) }
    let selected: Set<MarkedAlbum> = [
        MarkedAlbum(kind: .master, id: 1), MarkedAlbum(kind: .master, id: 9),
    ]
    #expect(rowsOf(selected, in: rows) == [1])
}

@MainActor
@Test func theWindowKeepsTheSelectedAlbumsAsADiscographyReorders() {
    let window = RecommendationsWindow()
    let show = { (ids: [Int]) in
        window.show(
            rows: ids.map { RecommendationRow(album: album($0)) }, query: discography,
            seeds: [.library, discography.seed], pending: false, message: nil, action: nil,
            facts: nil)
    }
    show([1, 2, 3])
    window.table.selectRowIndexes([0, 2], byExtendingSelection: false)
    show([3, 2, 1])
    #expect(window.table.selectedRowIndexes == [0, 2])
    window.table.selectRowIndexes([1], byExtendingSelection: false)
    show([2, 3, 1, 4])
    #expect(window.table.selectedRowIndexes == [0])
}

@MainActor
@Test func aDiscographysColumnsShowAndTheScoredListsComeBackAsTheyWere() throws {
    let window = RecommendationsWindow()
    let hidden = { (column: RecommendationColumn) in
        window.table.tableColumns.first { $0.identifier.rawValue == column.rawValue }?.isHidden
    }
    let show = { (query: RecommendationQuery) in
        window.show(
            rows: [], query: query, seeds: [.library, discography.seed], pending: false,
            message: nil, action: nil, facts: nil)
    }
    show(RecommendationQuery(sort: .rating))
    #expect(hidden(.why) == false && hidden(.format) == true && hidden(.mark) == true)
    let header = try #require(window.table.headerView?.menu)
    window.menuNeedsUpdate(header)
    #expect(!header.items.map(\.title).contains("Format"))
    let why = try #require(header.items.first { $0.title == "Why" })
    NSApplication.shared.sendAction(try #require(why.action), to: why.target, from: why)
    #expect(hidden(.why) == true)

    show(discography)
    for column in [RecommendationColumn.why, .score, .rank] { #expect(hidden(column) == true) }
    for column in [RecommendationColumn.format, .inLibrary, .mark] {
        #expect(hidden(column) == false)
    }
    window.menuNeedsUpdate(header)
    #expect(!header.items.map(\.title).contains("Why"))
    #expect(header.items.map(\.title).contains("In Library"))
    #expect(!window.viewControl.isEnabled)
    #expect(window.missingBox.toolTip == RecommendationsWindow.missingDiscographyHelp)

    show(RecommendationQuery(sort: .have))
    #expect(hidden(.why) == true && hidden(.title) == false && hidden(.format) == true)
}

@Test func aDiscographysColumnsSayTheFormatsTheLibraryAndTheMark() {
    var owned = album(7)
    owned.formats = ["Vinyl, LP, Album", "CD, Album"]
    owned.inLibrary = true
    owned.mark = .alreadyHave
    let row = RecommendationRow(album: owned)
    #expect(RecommendationColumn.format.text(row, download: nil) == "Vinyl, LP, Album; CD, Album")
    #expect(RecommendationColumn.inLibrary.text(row, download: nil) == "Yes")
    #expect(RecommendationColumn.mark.text(row, download: nil) == "Already Have")
    #expect(RecommendationColumn.score.text(row, download: nil) == "0.50")
    owned.score = nil
    #expect(RecommendationColumn.score.text(RecommendationRow(album: owned), download: nil) == "")
}
