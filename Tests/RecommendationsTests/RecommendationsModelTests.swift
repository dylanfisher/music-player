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
