/// Where a download job is in its lifecycle. The service sets the states up to `staged`, the
/// player those from `approved` on, and either one `failed` and `cancelled`.
package enum JobState: String, Equatable, Sendable, CaseIterable, Decodable {
    /// Waiting for its search.
    case queued
    case searching
    /// No candidate passed; `nextAttemptAt` says when it tries again.
    case notFound = "not_found"
    /// A candidate is chosen; the download is being enqueued.
    case candidateFound = "candidate_found"
    /// Transfers are running; see `progress`.
    case downloading
    /// Every file is complete in slskd's folder, not yet copied.
    case downloaded
    /// Copied to `stagedPath` and checked: the player tags it, and the owner reviews it.
    case staged
    case approved
    /// The player is moving files, deleting old ones, carrying stats.
    case importing
    case imported
    /// The service deletes the staged folder.
    case rejected
    /// See `failedStage` and `reason`.
    case failed
    case cancelled

    /// Thrown as `UnknownJobState` for a name the contract doesn't have, so the caller can
    /// show it as an error rather than skip the job.
    package init(from decoder: any Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        guard let state = JobState(rawValue: name) else { throw UnknownJobState(name: name) }
        self = state
    }
}
