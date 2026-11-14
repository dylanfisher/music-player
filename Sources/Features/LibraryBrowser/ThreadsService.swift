import Recommender

/// The call Threads makes to music-recommender, so tests can stand in for the service. It
/// throws the client's error, which names the address tried.
package struct ThreadsService: Sendable {
    /// The threads of the album the profile keys so.
    var threads: @Sendable (String) async throws(RecommenderError) -> AlbumThreads
}

extension ThreadsService {
    /// The call on the client `client` makes, made for each call so a network that comes up
    /// later is found.
    package init(client: @escaping @Sendable () throws(RecommenderError) -> RecommenderClient) {
        threads = { key throws(RecommenderError) in try await client().threads(key: key) }
    }
}
