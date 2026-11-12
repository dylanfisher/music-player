import Foundation
import Testing

@testable import Recommendations
@testable import Recommender

/// Records a call the test didn't expect, and fails it.
func unexpected(_ call: String) -> RecommenderError {
    Issue.record("the test didn't expect \(call)")
    return RecommenderError(service: "the fake", kind: .cancelled)
}

extension RecommendationsService {
    /// A service whose every call fails the test; each test sets the calls it expects.
    static var unused: RecommendationsService {
        RecommendationsService(
            page: { _, _, _ throws(RecommenderError) in throw unexpected("a page") },
            sendProfile: { _ throws(RecommenderError) in throw unexpected("the profile") },
            mark: { _, _, _ throws(RecommenderError) in throw unexpected("a mark") },
            unmark: { _, _ throws(RecommenderError) in throw unexpected("an undo") },
            marks: { () throws(RecommenderError) in throw unexpected("the marks") })
    }
}

/// A recommended master `id`, with nothing but its title and rank.
func album(_ id: Int, releaseID: Int? = nil) -> RecommendationPage.Album {
    RecommendationPage.Album(
        kind: .master, id: id, releaseID: releaseID ?? id + 1000, rank: id, score: 0.5,
        artists: [RecommendationPage.Named(id: 1, name: "Made-Up Artist")],
        title: "Album \(id)", year: 2001, label: nil, styles: [], community: nil, reasons: [])
}

let facts = RecommendationPage.Facts(
    catalogSet: "20261001", computedAt: 1_800_000_000, seeds: 3, candidates: 100)

/// A page of the albums `ids`.
func page(_ ids: some Sequence<Int>, more: Bool) -> RecommendationPage {
    RecommendationPage(list: facts, albums: ids.map { album($0) }, artists: nil, more: more)
}

/// The requests a fake service was sent, in order.
final class Requests: @unchecked Sendable {
    private let lock = NSLock()
    private var got: [(query: RecommendationQuery, offset: Int, limit: Int)] = []

    func append(_ query: RecommendationQuery, _ offset: Int, _ limit: Int) {
        lock.withLock { got.append((query, offset, limit)) }
    }

    var offsets: [Int] { lock.withLock { got.map(\.offset) } }
    var queries: [RecommendationQuery] { lock.withLock { got.map(\.query) } }
}

/// A list of `total` albums, numbered from 0, served `limit` at a time, recording each request.
func list(_ total: Int, _ requests: Requests) -> RecommendationsService {
    var service = RecommendationsService.unused
    service.page = { query, offset, limit in
        requests.append(query, offset, limit)
        let end = min(total, offset + limit)
        return page(offset..<end, more: end < total)
    }
    return service
}

/// A sleep that returns at once, counting the seconds it was asked for.
final class Sleeps: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [Double] = []

    var seconds: [Double] { lock.withLock { asked } }

    var sleep: @Sendable (Double) async throws -> Void {
        { [self] seconds in lock.withLock { asked.append(seconds) } }
    }
}

/// The marks and undos a fake service was sent, in order, as "kind id".
final class MarkCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var got: [String] = []

    func append(_ call: String) { lock.withLock { got.append(call) } }

    var calls: [String] { lock.withLock { got } }
}
