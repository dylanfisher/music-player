import Foundation
import Recommender

/// The Downloads window's state, with no AppKit: the service's jobs as rows, and the polling
/// that keeps them current. It polls every 2 s while the window is open and a job is moving,
/// and every 60 s otherwise, from launch to quit, so a job queued on another Mac appears. The
/// requests run off the main actor; only the rows are kept here.
@MainActor
final class DownloadsModel {
    /// Waits about this many seconds. Throws when cancelled.
    typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    /// The poll's interval while the window is open and a job is moving.
    nonisolated static let activeInterval: TimeInterval = 2
    /// The poll's interval otherwise.
    nonisolated static let idleInterval: TimeInterval = 60

    /// Whether the service answered the last poll.
    enum Connection: Equatable {
        /// Before the first reply.
        case waiting
        case answering
        /// The last poll failed, saying why and naming the address tried; the rows are as
        /// they were at `lastGood`, nil when no poll has answered yet.
        case down(String, lastGood: Date?)
    }

    private let service: DownloadsService
    /// This Mac's name, as the service knows it.
    let machine: String
    private let now: () -> Date
    private let sleep: Sleep

    private(set) var jobs = DownloadJobs()
    private(set) var rows: [DownloadRow] = []
    private(set) var connection = Connection.waiting
    private(set) var isWindowOpen = false
    private var lastGood: Date?
    private var polling: Task<Void, Never>?
    /// The last poll started, which the next waits for.
    private var lastPoll: Task<Void, Never>?

    /// Called after anything shown changes.
    var changed: () -> Void = {}
    /// Hears every job after each poll that answered, for the coordinator.
    var took: ([DownloadJob]) -> Void = { _ in }

    init(
        service: DownloadsService, machine: String, now: @escaping () -> Date = Date.init,
        sleep: @escaping Sleep = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1e9))
        }
    ) {
        self.service = service
        self.machine = machine
        self.now = now
        self.sleep = sleep
    }

    /// Whether `job` changes often enough to poll it every 2 s: the service is working on it,
    /// or the player is tagging or importing it. A job waiting for the owner, or for a search
    /// hours away, isn't.
    nonisolated static func isMoving(_ job: DownloadJob) -> Bool {
        switch job.state {
        case .queued, .searching, .candidateFound, .downloading, .downloaded, .approved,
            .importing:
            true
        case .staged: job.tagging.status == .none || job.tagging.status == .running
        case .notFound, .failed, .imported, .rejected, .cancelled: false
        }
    }

    /// How long to wait before the next poll.
    nonisolated static func interval(windowOpen: Bool, jobs: some Sequence<DownloadJob>)
        -> TimeInterval
    {
        windowOpen && jobs.contains(where: isMoving) ? activeInterval : idleInterval
    }

    /// Starts polling, with a poll now.
    func start() { restart(pollingFirst: true) }

    /// Stops polling, at quit.
    func stop() {
        polling?.cancel()
        polling = nil
    }

    /// Opening the window polls at once and then at its pace; closing it cancels the request
    /// running and goes back to the idle pace.
    func setWindowOpen(_ open: Bool) {
        guard open != isWindowOpen else { return }
        isWindowOpen = open
        guard polling != nil else { return }
        restart(pollingFirst: open)
    }

    private func restart(pollingFirst: Bool) {
        polling?.cancel()
        polling = Task { [weak self] in
            var pollNow = pollingFirst
            while !Task.isCancelled {
                guard let self else { return }
                if pollNow { await self.poll() }
                pollNow = true
                let wait = Self.interval(windowOpen: self.isWindowOpen, jobs: self.jobs.rows.values)
                let sleep = self.sleep
                do {
                    try await sleep(wait)
                } catch {
                    return
                }
            }
        }
    }

    /// Brings the jobs up to date, after any poll before it: each asks from the jobs the one
    /// before it left, so an old reply can't overwrite a newer one. A reply that resets the
    /// epoch drops every row first; a failure keeps the rows as they were, dimmed, and says why.
    /// Cancelling the caller cancels the request.
    func poll() async {
        let before = lastPoll
        let mine = Task { [self] in
            await before?.value
            await refresh()
        }
        lastPoll = mine
        await withTaskCancellationHandler {
            await mine.value
        } onCancel: {
            mine.cancel()
        }
    }

    private func refresh() async {
        guard !Task.isCancelled else { return }
        let refreshed = service.refreshed
        let before = jobs
        let connectionBefore = connection
        do throws(RecommenderError) {
            let next = try await refreshed(before)
            guard !Task.isCancelled else { return }
            jobs = next
            lastGood = now()
            connection = .answering
            took(Array(next.rows.values))
        } catch {
            // A poll the window's closing cancelled isn't the service failing.
            guard !Task.isCancelled else { return }
            connection = .down(error.description, lastGood: lastGood)
        }
        // Most polls find nothing new; the rows and the window are left alone then.
        guard jobs.rows != before.rows || connection != connectionBefore else { return }
        buildRows()
        changed()
    }

    /// Takes a job a call the window made answered with, so the row shows it before the next
    /// poll.
    func took(_ job: DownloadJob) {
        jobs.rows[job.id] = job
        buildRows()
        changed()
    }

    /// The job a row shows.
    func job(_ id: Int) -> DownloadJob? { jobs.rows[id] }

    /// Starts the job `id` again, with `policy` for a retry that searches again. Nil when the
    /// service took it, else why not.
    func retry(_ id: Int, policy: FormatPolicy?) async -> String? {
        let retry = service.retry
        return await answer { () throws(RecommenderError) in try await retry(id, policy) }
    }

    func cancel(_ id: Int) async -> String? {
        let cancel = service.cancel
        return await answer { () throws(RecommenderError) in try await cancel(id) }
    }

    /// Queues each of `orders`, in order, and returns why each one the service refused was.
    func create(_ orders: [(snapshot: ReleaseSnapshot, order: JobOrder)]) async -> [String] {
        let create = service.create
        var problems: [String] = []
        for (snapshot, order) in orders {
            if let problem = await answer({ () throws(RecommenderError) in
                try await create(snapshot, order)
            }) {
                problems.append("\(snapshot.artist) - \(snapshot.title): \(problem)")
            }
        }
        return problems
    }

    /// Runs `call` and shows the job it answers with; nil then, else what it threw.
    private func answer(_ call: () async throws(RecommenderError) -> DownloadJob) async
        -> String?
    {
        do throws(RecommenderError) {
            took(try await call())
            return nil
        } catch {
            return error.description
        }
    }

    /// The window's status line: what's wrong with the service, else what this Mac can't do,
    /// then the coordinator's `problems`, newest last. Empty when there's nothing to say.
    nonisolated static func status(
        _ connection: Connection, canAdd: Bool, problems: [String],
        formatted: (Date) -> String
    ) -> String {
        var lines: [String] = []
        switch connection {
        case .waiting: lines.append("Asking music-recommender for its downloads…")
        case .answering: break
        case .down(let why, let lastGood):
            lines.append(
                "Can't reach the service: \(why)."
                    + (lastGood.map { " The rows are as they were at \(formatted($0))." } ?? ""))
        }
        if !canAdd {
            lines.append(
                "There's no Discogs catalog on this Mac, so it can't queue or tag downloads.")
        }
        lines += problems
        return lines.joined(separator: " ")
    }

    private func buildRows() {
        let answering = connection == .answering
        rows = jobs.rows.values.compactMap {
            DownloadRow($0, machine: machine, answering: answering)
        }.sorted(by: DownloadRow.listed)
    }
}
