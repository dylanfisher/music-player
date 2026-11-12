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
