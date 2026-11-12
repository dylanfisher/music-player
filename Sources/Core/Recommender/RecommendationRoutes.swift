/// The service's lists of albums the library doesn't have (`docs/api.md` there, section
/// Recommendations; its ADR 0028).
extension RecommenderClient {
    /// Most rows a page may ask for.
    static let pageLimit = 100

    /// Longest a request for a list waits. A seed list's first request computes it, about
    /// 23 s on the owner's catalog, and up to 4 wait behind each other, so the worst wait is
    /// about 90 s; 120 s leaves room for a slower catalog. Other lists answer at once.
    static let seedListTimeoutSeconds = 120.0

    /// The `limit` rows of `query`'s list from `offset`.
    func recommendations(
        _ query: RecommendationQuery, offset: Int, limit: Int = pageLimit
    ) async throws(RecommenderError) -> RecommendationPage {
        try await call(
            "/v1/recommendations",
            body: RecommendationRequest(query: query, offset: offset, limit: limit),
            as: RecommendationPage.self, timeoutSeconds: Self.seedListTimeoutSeconds)
    }
}
