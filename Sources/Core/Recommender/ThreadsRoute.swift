/// Threads: the library's albums connected to one of them (`docs/api.md` there, section
/// Threads; ADR 0208).
extension RecommenderClient {
    /// The threads of the album the profile keys `key`. The service answers from what
    /// Rediscover keeps, within the usual timeout.
    package func threads(key: String) async throws(RecommenderError) -> AlbumThreads {
        try await call("/v1/threads", body: ThreadsRequest(key: key), as: AlbumThreads.self)
    }
}

private struct ThreadsRequest: Encodable {
    var key: String
}
