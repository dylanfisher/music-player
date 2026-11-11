/// The player's copy of the service's jobs, and where its paging through `downloads/list` got
/// to. A job that changed comes whole and replaces its row; nothing is sent as a difference.
package struct DownloadJobs: Equatable, Sendable {
    /// Every job the service has, by id, as of the last page taken.
    package var rows: [Int: DownloadJob] = [:]
    /// The store's epoch from the last reply; nil before the first.
    package internal(set) var epoch: String?
    /// The revision of the last job taken, 0 before any.
    package var after = 0

    package init() {}

    /// Takes one page of `downloads/list`. A reset drops every row first, wherever in the
    /// paging it comes. A page that doesn't advance is refused, so paging can't loop: its jobs
    /// must be in ascending revision above `after`, and `more` needs at least one.
    package mutating func take(_ page: JobPage) throws(RecommenderError.Kind) {
        if !page.reset, let epoch, epoch != page.epoch {
            throw .unreadable(
                "the epoch changed from \(epoch.debugDescription) to"
                    + " \(page.epoch.debugDescription) without a reset")
        }
        if page.more, page.jobs.isEmpty {
            throw .unreadable("a page with more to come has no jobs")
        }
        var next = page.reset ? 0 : after
        for job in page.jobs {
            guard job.revision > next else {
                throw .unreadable(
                    "job \(job.id)'s revision \(job.revision) doesn't follow \(next)")
            }
            next = job.revision
        }
        if page.reset { rows = [:] }
        for job in page.jobs { rows[job.id] = job }
        after = next
        epoch = page.epoch
    }
}

/// One reply of `downloads/list`.
package struct JobPage: Equatable, Sendable, Decodable {
    var epoch: String
    /// The store's revision now, the highest any job has.
    var revision: Int
    /// The client's rows are gone: the page starts from the beginning.
    var reset: Bool
    /// Jobs remain past the last of `jobs`.
    var more: Bool
    /// In ascending revision, each once.
    package var jobs: [DownloadJob]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case ok, epoch, revision, reset, more, jobs
    }

    init(epoch: String, revision: Int, reset: Bool, more: Bool, jobs: [DownloadJob]) {
        self.epoch = epoch
        self.revision = revision
        self.reset = reset
        self.more = more
        self.jobs = jobs
    }

    package init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        epoch = try container.decode(String.self, forKey: .epoch)
        revision = try container.decode(Int.self, forKey: .revision)
        reset = try container.decode(Bool.self, forKey: .reset)
        more = try container.decode(Bool.self, forKey: .more)
        jobs = try container.decode([DownloadJob].self, forKey: .jobs)
    }
}
