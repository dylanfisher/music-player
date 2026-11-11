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

    /// The jobs a state ends in; they change no more.
    static let terminal: Set<JobState> = [.imported, .rejected, .cancelled]

    /// The steps for `own`, the jobs it queued, from `jobs`, the service's as listed in
    /// `epoch`, and how many stay in flight. `notClean` holds the jobs Approve Safe Matches
    /// Automatically found a lossy-origin finding in. A job tagged `discrepancy` is
    /// requeued only once no Mac holds its tagging lease, which the run gives up after its
    /// report.
    static func steps(
        own: [AutoUpgradeJob], jobs: [Int: DownloadJob], epoch: String, notClean: Set<Int>
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
            case .staged
            where (job.tagging.status == .discrepancy && job.lease == nil)
                || notClean.contains(job.id):
                steps.append(.requeue(mine))
                inFlight += 1
            default: inFlight += 1
            }
        }
        return (steps, inFlight)
    }

    /// Up to `room` of `candidates` to queue, highest score first: none marked Never Upgrade
    /// (`never`), set aside or waiting after a miss at `now`, or with a job on the service for
    /// its release that isn't ended, from either Mac, and none in `skipped`.
    static func next(
        _ candidates: [UpgradeCandidate], jobs: some Sequence<DownloadJob>, never: Set<Int>,
        misses: [Int: UpgradeMiss], skipped: Set<Int>, now: Date, room: Int
    ) -> [UpgradeCandidate] {
        guard room > 0 else { return [] }
        let active = Set(jobs.filter { !terminal.contains($0.state) }.map(\.release.releaseID))
        let seconds = now.timeIntervalSince1970
        return candidates.filter { candidate in
            let release = candidate.releaseID
            if never.contains(release) || active.contains(release) || skipped.contains(release) {
                return false
            }
            guard let miss = misses[release] else { return true }
            return miss.retryAt.map { $0 <= seconds } ?? false
        }
        .sorted { $0.precedes($1) }
        .prefix(room)
        .map { $0 }
    }
}
