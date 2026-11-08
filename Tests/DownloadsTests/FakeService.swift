import Foundation
import Testing

@testable import Downloads
@testable import LocalNetwork
@testable import Recommender

// Stand-ins for music-recommender and the clock, for the model's and the coordinator's tests:
// no network and no real sleeps.

/// A job of the release 4242, manual, staged with two files and not yet tagged; `change`
/// sets the rest.
func job(
    _ id: Int, _ state: JobState = .staged, revision: Int = 1, created: Int = 1_794_060_000,
    _ change: (inout DownloadJob) -> Void = { _ in }
) -> DownloadJob {
    let json = #"""
        {"id": 1, "revision": 1, "source": "manual", "format_policy": "flac",
         "release": {"release_id": 4242, "artist": "Made-Up Artist", "title": "Made-Up Album", "year": 1999},
         "state": "staged", "failed_stage": null, "reason": null, "attempt": 1, "next_attempt_at": null,
         "progress": null,
         "candidate": {"peer": "made-up-peer", "format": "flac", "bit_depth": 16, "sample_rate": 44100,
                       "bitrate": null, "variable_bitrate": null, "file_count": 2, "bytes": 55574528,
                       "tracklist": 0},
         "files": [{"name": "01 First Song.flac", "size": 24117248, "position": "1"},
                   {"name": "02 Second Song.flac", "size": 31457280, "position": "2"}],
         "staged_path": "job-1", "tagging": {"status": "none", "reasons": []}, "lease": null,
         "review": null, "upgrade": null, "cleanup_pending": false,
         "created_at": 1794060000, "updated_at": 1794063600}
        """#
    var job: DownloadJob
    do {
        job = try replyDecoder.decode(DownloadJob.self, from: Data(json.utf8))
    } catch {
        preconditionFailure("the base job decodes: \(error)")
    }
    job.id = id
    job.revision = revision
    job.state = state
    job.stagedPath = "job-\(id)"
    job.createdAt = created
    change(&job)
    return job
}

/// A clock whose sleeps wait until a test moves it on.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 1_794_100_000
    private var sleepers:
        [Int: (deadline: TimeInterval, wake: CheckedContinuation<Void, any Error>)] =
            [:]
    private var cancelledEarly: Set<Int> = []
    private var nextID = 0

    var now: TimeInterval { lock.withLock { time } }

    /// How long each sleep waiting now asked for, in the order they began.
    var waiting: [TimeInterval] {
        lock.withLock {
            sleepers.sorted { $0.key < $1.key }.map { $0.value.deadline - time }
        }
    }

    func sleep(_ seconds: TimeInterval) async throws {
        let id = lock.withLock {
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (wake: CheckedContinuation<Void, any Error>) in
                let cancelled = lock.withLock {
                    if cancelledEarly.remove(id) != nil { return true }
                    sleepers[id] = (time + seconds, wake)
                    return false
                }
                if cancelled { wake.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let wake = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                if let sleeper = sleepers.removeValue(forKey: id) { return sleeper.wake }
                cancelledEarly.insert(id)
                return nil
            }
            wake?.resume(throwing: CancellationError())
        }
    }

    /// Moves the time on, waking each sleep that's due.
    func advance(by seconds: TimeInterval) {
        let due = lock.withLock {
            time += seconds
            let due = sleepers.filter { $0.value.deadline <= time }
            for id in due.keys { sleepers[id] = nil }
            return due.values.map(\.wake)
        }
        for wake in due { wake.resume() }
    }
}

/// Yields until `condition` holds, failing the test if it never does.
func eventually(
    _ what: String, isolation: isolated (any Actor)? = #isolation,
    sourceLocation: SourceLocation = #_sourceLocation, _ condition: () async -> Bool
) async {
    for _ in 0..<20_000 {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("never: \(what)", sourceLocation: sourceLocation)
}

/// music-recommender's job store, as far as the player sees it: the list's paging by epoch
/// and revision, and `handoff`'s leases and claims by machine, which expire on `clock`.
final class FakeService: @unchecked Sendable {
    private let lock = NSLock()
    let clock: FakeClock
    private var store: [Int: DownloadJob] = [:]
    private var revision = 0
    private var epochValue = "e1"
    private var isDown = false
    private var failNext = 0
    private var sent: [(id: Int, event: HandoffEvent)] = []
    private var lists: [(epoch: String?, after: Int)] = []

    init(clock: FakeClock = FakeClock(), _ jobs: [DownloadJob] = []) {
        self.clock = clock
        for job in jobs { put(job) }
    }

    /// The calls as the model and the coordinator take them.
    var service: DownloadsService {
        DownloadsService(
            refreshed: { jobs throws(RecommenderError) in try self.refreshed(jobs) },
            handoff: { id, event throws(RecommenderError) in try self.handoff(id, event) },
            create: { snapshot, order throws(RecommenderError) in try self.create(snapshot, order) },
            retry: { id, policy throws(RecommenderError) in try self.retry(id, policy) },
            cancel: { id throws(RecommenderError) in try self.cancel(id) })
    }

    /// Every job created, with its order.
    var created: [(release: Int, order: JobOrder)] { lock.withLock { orders } }
    private var orders: [(release: Int, order: JobOrder)] = []

    private func create(_ snapshot: ReleaseSnapshot, _ order: JobOrder) throws(RecommenderError)
        -> DownloadJob
    {
        try locked { () throws(RecommenderError) -> DownloadJob in
            if isDown { throw unreachable("/v1/downloads/create") }
            if store.values.contains(where: {
                $0.release.releaseID == snapshot.releaseID
                    && ![.imported, .rejected, .cancelled].contains($0.state)
            }) {
                throw RecommenderError(
                    service: "fake",
                    kind: .refused(ServiceRefusal(code: .alreadyActive, message: "already_active")))
            }
            orders.append((snapshot.releaseID, order))
            revision += 1
            var made = DownloadsTests.job((store.keys.max() ?? 0) + 1, .queued)
            made.release.releaseID = snapshot.releaseID
            made.revision = revision
            store[made.id] = made
            return made
        }
    }

    private func retry(_ id: Int, _ policy: FormatPolicy?) throws(RecommenderError) -> DownloadJob {
        try change(id, "/v1/downloads/retry") { job in
            job.state = .queued
            job.failedStage = nil
            if let policy { job.formatPolicy = policy }
        }
    }

    private func cancel(_ id: Int) throws(RecommenderError) -> DownloadJob {
        try change(id, "/v1/downloads/cancel") { $0.state = .cancelled }
    }

    private func change(_ id: Int, _ path: String, _ body: (inout DownloadJob) -> Void)
        throws(RecommenderError) -> DownloadJob
    {
        try locked { () throws(RecommenderError) -> DownloadJob in
            if isDown { throw unreachable(path) }
            guard var job = store[id] else {
                throw RecommenderError(
                    service: "fake",
                    kind: .refused(ServiceRefusal(code: .noSuchJob, message: "no_such_job")))
            }
            body(&job)
            revision += 1
            job.revision = revision
            store[id] = job
            return job
        }
    }

    /// Stores `job` at the next revision, as a change the service made.
    func put(_ job: DownloadJob) {
        lock.withLock {
            revision += 1
            var job = job
            job.revision = revision
            store[job.id] = job
        }
    }

    func job(_ id: Int) -> DownloadJob? { lock.withLock { store[id].map(live) } }

    /// A rebuilt store: a new epoch, and the jobs given at revisions from 1.
    func rebuild(_ jobs: [DownloadJob]) {
        lock.withLock {
            epochValue += "'"
            store = [:]
            revision = 0
        }
        for job in jobs { put(job) }
    }

    /// Whether every call fails as unreachable.
    var down: Bool {
        get { lock.withLock { isDown } }
        set { lock.withLock { isDown = newValue } }
    }

    /// Makes the next `count` handoffs fail as unreachable.
    func failHandoffs(_ count: Int) { lock.withLock { failNext = count } }

    /// Every handoff sent, in order.
    var events: [(id: Int, event: HandoffEvent)] { lock.withLock { sent } }
    /// The events sent, as the outbox writes them, without the id.
    var eventTypes: [String] { events.map { type($0.event) } }
    /// Every list request's epoch and revision.
    var listed: [(epoch: String?, after: Int)] { lock.withLock { lists } }

    /// `body` under the lock, keeping its error's type, which `withLock` doesn't.
    private func locked<T>(_ body: () throws(RecommenderError) -> T) throws(RecommenderError) -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func unreachable(_ path: String) -> RecommenderError {
        RecommenderError(
            service: "http://192.0.2.7:8080\(path)", kind: .unreachable(.timedOut))
    }

    private func refreshed(_ jobs: DownloadJobs) throws(RecommenderError) -> DownloadJobs {
        let page = try locked { () throws(RecommenderError) -> JobPage in
            lists.append((jobs.epoch, jobs.after))
            if isDown { throw unreachable("/v1/downloads/list") }
            let reset = jobs.epoch != nil && jobs.epoch != epochValue
            let after = reset ? 0 : jobs.after
            return JobPage(
                epoch: epochValue, revision: revision, reset: reset, more: false,
                jobs: store.values.filter { $0.revision > after }.sorted {
                    $0.revision < $1.revision
                }.map(live))
        }
        var jobs = jobs
        do throws(RecommenderError.Kind) {
            try jobs.take(page)
        } catch {
            throw RecommenderError(service: "fake", kind: error)
        }
        return jobs
    }

    /// `job` with its expired holds read as none, as the service lists it.
    private func live(_ job: DownloadJob) -> DownloadJob {
        var job = job
        let now = Int(clock.now)
        if let lease = job.lease, lease.expiresAt <= now { job.lease = nil }
        if let review = job.review, review.expiresAt <= now { job.review = nil }
        return job
    }

    /// The machine every coordinator under test runs as.
    static let machine = "Studio"

    private func handoff(_ id: Int, _ event: HandoffEvent) throws(RecommenderError)
        -> DownloadJob
    {
        try locked { () throws(RecommenderError) -> DownloadJob in
            sent.append((id, event))
            if isDown { throw unreachable("/v1/downloads/handoff") }
            if failNext > 0 {
                failNext -= 1
                throw unreachable("/v1/downloads/handoff")
            }
            let refuse = { (code: ServiceRefusal.Code, holder: DownloadJob.Hold?) in
                var refusal = ServiceRefusal(code: code, message: "\(code.rawValue)")
                refusal.machine = holder?.machine
                refusal.expiresAt = holder?.expiresAt
                return RecommenderError(service: "fake", kind: .refused(refusal))
            }
            guard var job = store[id].map(live) else { throw refuse(.noSuchJob, nil) }
            let me = Self.machine
            let now = Int(clock.now)
            let illegal = refuse(.illegalTransition, nil)
            func needLease() throws(RecommenderError) {
                guard job.state == .staged else { throw illegal }
                guard let lease = job.lease else { throw refuse(.notClaimed, nil) }
                guard lease.machine == me else { throw refuse(.claimed, lease) }
            }
            func needClaim(_ states: [JobState]) throws(RecommenderError) {
                guard states.contains(job.state) else { throw illegal }
                guard let review = job.review else { throw refuse(.notClaimed, nil) }
                guard review.machine == me else { throw refuse(.claimed, review) }
            }
            switch event {
            case .lease:
                guard job.state == .staged else { throw illegal }
                if let lease = job.lease, lease.machine != me { throw refuse(.claimed, lease) }
                job.lease = DownloadJob.Hold(machine: me, expiresAt: now + 600)
            case .releaseLease:
                if job.lease?.machine == me { job.lease = nil }
            case .tagging(let tagging):
                try needLease()
                job.tagging = tagging
            case .claim(let takeOver):
                guard [.staged, .approved, .importing].contains(job.state) else { throw illegal }
                if let review = job.review, review.machine != me,
                    !(takeOver && job.state != .staged)
                {
                    throw refuse(.claimed, review)
                }
                job.review = DownloadJob.Hold(machine: me, expiresAt: now + 86_400)
            case .release:
                if job.review?.machine == me { job.review = nil }
            case .approved:
                if job.state != .approved {
                    try needClaim([.staged])
                    guard job.tagging.status == .clean else { throw illegal }
                    job.state = .approved
                }
            case .importing:
                if job.state != .importing {
                    try needClaim([.approved])
                    job.state = .importing
                }
            case .imported:
                if job.state != .imported {
                    try needClaim([.approved, .importing])
                    job.state = .imported
                }
            case .rejected:
                if job.state != .rejected {
                    try needClaim([.staged])
                    job.state = .rejected
                }
            case .failed:
                try needClaim([.approved, .importing])
                job.state = .failed
            }
            revision += 1
            job.revision = revision
            store[id] = job
            return job
        }
    }
}

/// An event's `type`, as the outbox writes it.
func type(_ event: HandoffEvent) -> String {
    switch event {
    case .lease: "lease"
    case .releaseLease: "release_lease"
    case .tagging(let tagging): "tagging \(tagging.status.rawValue)"
    case .claim(let takeOver): takeOver ? "claim take_over" : "claim"
    case .release: "release"
    case .approved: "approved"
    case .importing: "importing"
    case .imported: "imported"
    case .rejected: "rejected"
    case .failed(let stage, _): "failed \(stage.rawValue)"
    }
}
