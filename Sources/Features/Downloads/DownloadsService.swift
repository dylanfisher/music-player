import Recommender

/// The calls the Downloads window and its coordinator make to music-recommender, so tests can
/// stand in for the service. Each throws the client's error, which names the address tried.
struct DownloadsService: Sendable {
    /// `jobs` brought up to date from its epoch and revision, every page taken.
    var refreshed: @Sendable (DownloadJobs) async throws(RecommenderError) -> DownloadJobs
    /// Sends an event for the job with this id, as this Mac, and returns the job as it now is.
    var handoff: @Sendable (Int, HandoffEvent) async throws(RecommenderError) -> DownloadJob
}

extension DownloadsService {
    /// The calls on `client`, sent as `machine`, the same name on every request from this Mac.
    init(_ client: RecommenderClient, machine: String) {
        refreshed = { jobs throws(RecommenderError) in try await client.refreshed(jobs) }
        handoff = { id, event throws(RecommenderError) in
            try await client.handoff(id, machine: machine, event)
        }
    }
}
