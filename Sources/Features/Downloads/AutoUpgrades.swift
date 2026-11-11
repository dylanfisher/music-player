import Foundation
import Library
import Recommender

/// Upgrade to FLAC Automatically's decisions (ADR 0200), with no calls in them: what becomes
/// of each job it queued, after a poll, and which candidates fill the slots left.
enum AutoUpgrades {
    /// What a job of its own needs.
    enum Step: Equatable {
        /// Imported, or no longer listed in its epoch: forgotten, no miss.
        case forget(AutoUpgradeJob)
        /// Rejected or cancelled, by anyone: a miss.
        case miss(AutoUpgradeJob)
        /// Found nothing (`not_found`, or failed at its search or download): cancelled, so it
        /// holds no slot and doesn't search on the service's schedule, then a miss.
        case cancelThenMiss(AutoUpgradeJob)
        /// Staged with a copy that isn't clean: requeued, to search again from another peer.
        case requeue(AutoUpgradeJob)
    }

    /// The candidates a pass read, kept for the passes after it while the jobs, misses and
    /// marks they're chosen by stay the same: a poll with a slot free and nothing to queue
    /// doesn't read the whole library again.
    struct CandidatesRead {
        struct Key: Equatable {
            var share: String
            var epoch: String
            /// Each job's state: one that lands, or ends, changes the albums to upgrade.
            var states: [Int: JobState]
            var misses: [Int: UpgradeMiss]
            var never: Set<Int>
        }

        /// How long a read is kept, in seconds: a scan or a play changes the library with no
        /// job changing.
        static let kept: TimeInterval = 600

        var key: Key
        var at: Date
        var candidates: [UpgradeCandidate]

        /// The candidates kept, when they were read with `key` less than `kept` before `now`.
        func candidates(for key: Key, at now: Date) -> [UpgradeCandidate]? {
            key == self.key && now.timeIntervalSince(at) < Self.kept ? candidates : nil
        }
    }

    /// The jobs a state ends in; they change no more.
    static let terminal: Set<JobState> = [.imported, .rejected, .cancelled]

    /// The steps for `own`, the jobs it queued, from `jobs`, the service's as listed in
    /// `epoch`, and how many stay in flight. `notClean` holds the jobs Approve Safe Matches
    /// Automatically found a lossy-origin finding in, and `approvable` the staged ones it will
    /// look at. A job tagged `discrepancy` is requeued only once no Mac holds its tagging
    /// lease, which the run gives up after its report. A job left for the owner, failed past
    /// its download or staged for review, holds no slot.
    static func steps(
        own: [AutoUpgradeJob], jobs: [Int: DownloadJob], epoch: String,
        notClean: Set<AutoUpgradeJob>,
        approvable: Set<Int>
    ) -> (steps: [Step], inFlight: Int) {
        var steps: [Step] = []
        var inFlight = 0
        for mine in own {
            guard mine.epoch == epoch, let job = jobs[mine.jobID],
                job.release.releaseID == mine.releaseID
            else {
                steps.append(.forget(mine))
                continue
            }
            switch job.state {
            case .imported: steps.append(.forget(mine))
            case .rejected, .cancelled: steps.append(.miss(mine))
            case .notFound: steps.append(.cancelThenMiss(mine))
            case .failed where job.failedStage == .search || job.failedStage == .download:
                steps.append(.cancelThenMiss(mine))
            case .failed: break
            case .staged
            where (job.tagging.status == .discrepancy && job.lease == nil)
                || notClean.contains(mine):
                steps.append(.requeue(mine))
                inFlight += 1
            case .staged where !isMoving(job, approvable: approvable): break
            default: inFlight += 1
            }
        }
        return (steps, inFlight)
    }

    /// Whether a staged job is still on its way without the owner: being tagged, or tagged
    /// clean for Approve Safe Matches Automatically to look at.
    private static func isMoving(_ job: DownloadJob, approvable: Set<Int>) -> Bool {
        switch job.tagging.status {
        case .none, .running, .discrepancy: true
        case .clean: approvable.contains(job.id)
        case .error: false
        }
    }

    /// Up to `room` of `candidates` to queue, highest score first and one per release: none
    /// marked Never Upgrade (`never`), set aside or waiting after a miss at `now`, or with a
    /// job on the service for its release that isn't ended, from either Mac, and none in
    /// `skipped`.
    static func next(
        _ candidates: [UpgradeCandidate], jobs: some Sequence<DownloadJob>, never: Set<Int>,
        misses: [Int: UpgradeMiss], skipped: Set<Int>, now: Date, room: Int
    ) -> [UpgradeCandidate] {
        var taken = Set(jobs.filter { !terminal.contains($0.state) }.map(\.release.releaseID))
        let seconds = now.timeIntervalSince1970
        var chosen: [UpgradeCandidate] = []
        for candidate in candidates.sorted(by: { $0.precedes($1) }) where chosen.count < room {
            let release = candidate.releaseID
            if never.contains(release) || skipped.contains(release) { continue }
            if let miss = misses[release], !(miss.retryAt.map { $0 <= seconds } ?? false) {
                continue
            }
            // Two albums of one release make one job.
            guard taken.insert(release).inserted else { continue }
            chosen.append(candidate)
        }
        return chosen
    }
}
