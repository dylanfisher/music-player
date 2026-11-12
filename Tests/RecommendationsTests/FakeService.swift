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
            sendProfile: { _ throws(RecommenderError) in throw unexpected("the profile") })
    }
}
