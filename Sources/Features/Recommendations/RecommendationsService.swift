import Recommender

/// The calls the Recommendations window makes to music-recommender, so tests can stand in for
/// the service. Each throws the client's error, which names the address tried.
package struct RecommendationsService: Sendable {
    /// The rows of a list from an offset, at most a limit of them.
    var page:
        @Sendable (RecommendationQuery, Int, Int) async throws(RecommenderError) ->
            RecommendationPage
    /// Keeps the profile in place of the one before, answering what it queued.
    var sendProfile: @Sendable (LibraryProfile) async throws(RecommenderError) -> ProfileReceipt
    /// Sets a verdict on a master or release.
    var mark:
        @Sendable (AlbumKind, Int, FeedbackMark.Verdict) async throws(RecommenderError) ->
            FeedbackMark
    /// Removes the verdict on a master or release.
    var unmark: @Sendable (AlbumKind, Int) async throws(RecommenderError) -> Bool
    /// Every mark, oldest first.
    var marks: @Sendable () async throws(RecommenderError) -> [FeedbackMark]
}

extension RecommendationsService {
    /// The calls on the client `client` makes, made for each call so a network that comes up
    /// later is found.
    package init(client: @escaping @Sendable () throws(RecommenderError) -> RecommenderClient) {
        page = { query, offset, limit throws(RecommenderError) in
            try await client().recommendations(query, offset: offset, limit: limit)
        }
        sendProfile = { profile throws(RecommenderError) in
            try await client().sendProfile(profile)
        }
        mark = { kind, id, verdict throws(RecommenderError) in
            try await client().mark(kind, id, verdict: verdict)
        }
        unmark = { kind, id throws(RecommenderError) in try await client().unmark(kind, id) }
        marks = { () throws(RecommenderError) in try await client().marks() }
    }
}
