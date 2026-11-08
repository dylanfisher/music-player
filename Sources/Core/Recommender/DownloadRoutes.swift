/// The downloads routes, each answering with the whole job as it now is, and the paging
/// through `downloads/list`.
extension RecommenderClient {
    /// Queues `snapshot`'s release. Refused with `already_active` while a job for it isn't
    /// terminal, with that job's id.
    func create(_ snapshot: ReleaseSnapshot, _ order: JobOrder) async throws(RecommenderError)
        -> DownloadJob
    {
        try await call(
            "/v1/downloads/create", body: CreateRequest(snapshot: snapshot, order: order),
            as: JobReply.self
        ).job
    }

    /// Starts a job again from its failed stage; `policy` replaces its policy, for a retry that
    /// searches again.
    func retry(_ id: Int, policy: FormatPolicy? = nil) async throws(RecommenderError)
        -> DownloadJob
    {
        try await call(
            "/v1/downloads/retry", body: RetryRequest(id: id, formatPolicy: policy),
            as: JobReply.self
        ).job
    }

    func cancel(_ id: Int) async throws(RecommenderError) -> DownloadJob {
        try await call("/v1/downloads/cancel", body: CancelRequest(id: id), as: JobReply.self)
            .job
    }

    /// Sends `event` for the job `id` as `machine`, the same name on every request from this
    /// Mac.
    func handoff(_ id: Int, machine: String, _ event: HandoffEvent)
        async throws(RecommenderError) -> DownloadJob
    {
        try await call(
            "/v1/downloads/handoff",
            body: HandoffRequest(id: id, machine: machine, event: event), as: JobReply.self
        ).job
    }

    /// `jobs` brought up to date: every page from its epoch and revision until the service
    /// has no more.
    func refreshed(_ jobs: DownloadJobs) async throws(RecommenderError) -> DownloadJobs {
        var jobs = jobs
        while true {
            let page = try await call(
                Self.listPath, body: ListRequest(epoch: jobs.epoch, after: jobs.after),
                as: JobPage.self)
            do throws(RecommenderError.Kind) {
                try jobs.take(page)
            } catch {
                throw RecommenderError(service: url(Self.listPath).description, kind: error)
            }
            if !page.more { return jobs }
        }
    }

    private static let listPath = "/v1/downloads/list"
}

private struct ListRequest: Encodable {
    var epoch: String?
    var after: Int

    private enum CodingKeys: String, CodingKey {
        case epoch, after
    }

    /// `epoch` goes as `null` on the first request, not left out.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(epoch, forKey: .epoch)
        try container.encode(after, forKey: .after)
    }
}

private struct RetryRequest: Encodable {
    var id: Int
    var formatPolicy: FormatPolicy?

    private enum CodingKeys: String, CodingKey {
        case id
        case formatPolicy = "format_policy"
    }
}

private struct CancelRequest: Encodable {
    var id: Int
}

private struct HandoffRequest: Encodable {
    var id: Int
    var machine: String
    var event: HandoffEvent
}
