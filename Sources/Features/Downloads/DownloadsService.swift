import Recommender

/// The calls the Downloads window and its coordinator make to music-recommender, so tests can
/// stand in for the service. Each throws the client's error, which names the address tried.
package struct DownloadsService: Sendable {
    /// `jobs` brought up to date from its epoch and revision, every page taken.
    var refreshed: @Sendable (DownloadJobs) async throws(RecommenderError) -> DownloadJobs
    /// Sends an event for the job with this id, as this Mac, and returns the job as it now is.
    var handoff: @Sendable (Int, HandoffEvent) async throws(RecommenderError) -> DownloadJob
    /// Queues a release, returning the new job.
    var create: @Sendable (ReleaseSnapshot, JobOrder) async throws(RecommenderError) -> DownloadJob
    /// Starts a failed or unfound job again, with a new policy for one that searches again.
    var retry: @Sendable (Int, FormatPolicy?) async throws(RecommenderError) -> DownloadJob
    var cancel: @Sendable (Int) async throws(RecommenderError) -> DownloadJob
}

extension DownloadsService {
    /// The calls on the client `client` makes, sent as `machine`, the same name on every
    /// request from this Mac. The client is made for each call, so a network that comes up
    /// after launch, or a Mac that moves to another, is found on the next poll.
    package init(
        machine: String,
        client: @escaping @Sendable () throws(RecommenderError) -> RecommenderClient
    ) {
        refreshed = { jobs throws(RecommenderError) in try await client().refreshed(jobs) }
        handoff = { id, event throws(RecommenderError) in
            try await client().handoff(id, machine: machine, event)
        }
        create = { snapshot, order throws(RecommenderError) in
            try await client().create(snapshot, order)
        }
        retry = { id, policy throws(RecommenderError) in
            try await client().retry(id, policy: policy)
        }
        cancel = { id throws(RecommenderError) in try await client().cancel(id) }
    }
}
