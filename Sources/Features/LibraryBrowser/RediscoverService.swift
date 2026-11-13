import Recommender

/// The calls Rediscover makes to music-recommender, so tests can stand in for the service.
/// Each throws the client's error, which names the address tried.
package struct RediscoverService: Sendable {
    /// The albums of a day, `YYYY-MM-DD`.
    var day: @Sendable (String) async throws(RecommenderError) -> RediscoverDay
    /// Leaves the album the service names so out for 30 days, answering when the mark ends.
    var notNow: @Sendable (String) async throws(RecommenderError) -> Int
    /// Removes the album's mark, answering whether there was one.
    var undoNotNow: @Sendable (String) async throws(RecommenderError) -> Bool
}

extension RediscoverService {
    /// The calls on the client `client` makes, made for each call so a network that comes up
    /// later is found.
    package init(client: @escaping @Sendable () throws(RecommenderError) -> RecommenderClient) {
        day = { day throws(RecommenderError) in try await client().rediscover(day: day) }
        notNow = { id throws(RecommenderError) in try await client().notNow(id) }
        undoNotNow = { id throws(RecommenderError) in try await client().undoNotNow(id) }
    }
}
