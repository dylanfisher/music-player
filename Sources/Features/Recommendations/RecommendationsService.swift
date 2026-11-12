import Recommender

/// The calls the Recommendations window makes to music-recommender, so tests can stand in for
/// the service. Each throws the client's error, which names the address tried.
package struct RecommendationsService: Sendable {
    /// Keeps the profile in place of the one before, answering what it queued.
    var sendProfile: @Sendable (LibraryProfile) async throws(RecommenderError) -> ProfileReceipt
}

extension RecommendationsService {
    /// The calls on the client `client` makes, made for each call so a network that comes up
    /// later is found.
    package init(client: @escaping @Sendable () throws(RecommenderError) -> RecommenderClient) {
        sendProfile = { profile throws(RecommenderError) in
            try await client().sendProfile(profile)
        }
    }
}
