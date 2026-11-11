import Foundation
import Library
import Log
import Metadata
import Recommender

private let logger = moduleLogger()

/// Upgrade to FLAC Automatically (ADR 0200): after each poll, it settles the jobs it queued,
/// counting a miss, cancelling a job that found nothing, or requeuing a copy that isn't clean,
/// then queues the best candidates into the slots left. Approving them is Approve Safe
/// Matches Automatically's, as for any job.
extension Downloads {
    /// Starts a pass when the box is on and this Mac can queue upgrades: a session that can
    /// tag, its staging folder on the library's share, and the service answering. One runs at
    /// a time; a call during one runs another after it.
    func upgradeAutomatically() {
        guard autoUpgrade, let session, session.canTag, session.coordinator != nil,
            let share = session.setup.share, session.model.connection == .answering,
            session.model.jobs.epoch != nil
        else { return }
        guard upgrading == nil else {
            upgradeAgain = true
            return
        }
        upgradeAgain = false
        upgrading = Task {
            await upgradePass(session, share: share)
            guard self.session === session else { return }
            upgrading = nil
            if upgradeAgain { upgradeAutomatically() }
        }
    }

    /// Whether a pass may make its next call: the box still on, and the session and the
    /// service's epoch, which its jobs' ids belong to, the same.
    private func goesOn(_ session: Session, _ epoch: String) -> Bool {
        autoUpgrade && self.session === session && session.model.jobs.epoch == epoch
            && !Task.isCancelled
    }

    private func upgradePass(_ session: Session, share: String) async {
        let database = session.setup.databaseURL
        for job in unrecorded {
            let recorded = await record("job \(job.jobID) still isn't recorded as automatic") {
                try LibraryIndex(at: database).recordAutoUpgradeJob(job)
            }
            if recorded { unrecorded.remove(job) }
        }
        let read = await blockingFileWork {
            Result { () throws -> ([AutoUpgradeJob], [Int: UpgradeMiss], Set<Int>) in
                let index = try LibraryIndex(at: database)
                return (
                    try index.autoUpgradeJobs(), try index.upgradeMisses(),
                    try index.neverUpgradeReleases()
                )
            }
        }
        let recorded: [AutoUpgradeJob]
        let misses: [Int: UpgradeMiss]
        let never: Set<Int>
        do {
            (recorded, misses, never) = try read.get()
        } catch {
            return logger.error("the automatic upgrades couldn't be read: \(error)")
        }
        let own = recorded + unrecorded.subtracting(recorded).sorted { $0.jobID < $1.jobID }
        let model = session.model
        // Read with the rows, after the index: a reset during the read changes both.
        guard let epoch = model.jobs.epoch else { return }
        let rows = model.jobs.rows
        notClean.formIntersection(own)
        let machine = session.setup.machine
        let approvable =
            autoApprove
            ? Set(
                rows.values.filter {
                    Self.mayApproveUnasked($0, machine: machine)
                        && model.leftForReview[$0.id] == nil
                }.map(\.id)) : []
        let settled = AutoUpgrades.steps(
            own: own, jobs: rows, epoch: epoch, notClean: notClean,
            approvable: approvable)
        var inFlight = settled.inFlight
        for step in settled.steps {
            guard goesOn(session, epoch) else { return }
            if await take(step, session) { inFlight += 1 }
        }
        guard goesOn(session, epoch), inFlight < autoUpgradesInFlight else { return }
        let candidates: [UpgradeCandidate]
        let missed: [Int: UpgradeMiss]
        do {
            candidates = try await upgradeCandidates(database, share)
            // Read again: the steps may have counted misses.
            missed =
                settled.steps.isEmpty
                ? misses
                : try await blockingFileWork {
                    Result { try LibraryIndex(at: database).upgradeMisses() }
                }.get()
        } catch {
            return logger.error("the upgrade candidates couldn't be read: \(error)")
        }
        guard goesOn(session, epoch) else { return }
        let chosen = AutoUpgrades.next(
            candidates, jobs: session.model.jobs.rows.values, never: never, misses: missed,
            skipped: unqueueable, now: now(), room: autoUpgradesInFlight - inFlight)
        for candidate in chosen {
            guard goesOn(session, epoch) else { return }
            guard await queue(candidate, session, epoch: epoch) else { return }
        }
    }

    /// Takes one step; true when it couldn't end a job, which still holds its slot.
    private func take(_ step: AutoUpgrades.Step, _ session: Session) async -> Bool {
        let service = session.setup.service
        let database = session.setup.databaseURL
        switch step {
        case .forget(let job):
            unrecorded.remove(job)
            await record("job \(job.jobID) couldn't be forgotten") {
                try LibraryIndex(at: database).forgetAutoUpgradeJob(job)
            }
            return false
        case .miss(let job):
            await miss(job, database)
            return false
        case .cancelThenMiss(let job):
            do throws(RecommenderError) {
                session.model.took(try await service.cancel(job.jobID))
            } catch {
                // Only an illegal transition carries the job's state. Rejected or imported
                // since the poll, by the owner or the other Mac, it ended as any other; moved
                // on, retried and approved, it's kept, and the next poll says where it is.
                guard case .refused(let refusal) = error.kind,
                    let state = refusal.state.flatMap(JobState.init(rawValue:)),
                    AutoUpgrades.terminal.contains(state)
                else {
                    logger.info("job \(job.jobID), which found nothing, wasn't cancelled: \(error)")
                    return true
                }
                if state == .imported { return await take(.forget(job), session) }
            }
            await miss(job, database)
            return false
        case .requeue(let job):
            let id = job.jobID
            if session.model.job(id)?.review?.machine == session.setup.machine,
                let coordinator = session.coordinator
            {
                do throws(RecommenderError) {
                    session.model.took(try await coordinator.releaseReview(id))
                } catch {
                    logger.info("job \(id)'s review claim not given up to requeue it: \(error)")
                    return false
                }
            }
            do throws(RecommenderError) {
                session.model.took(try await service.requeue(id))
            } catch {
                // Held by a tag run or a review on a Mac, or gone: the next poll says.
                logger.info("job \(id), which isn't clean, wasn't requeued: \(error)")
                return false
            }
            logger.notice("job \(id) requeued unasked: its copy wasn't clean")
            notClean.remove(job)
            session.model.leave(id, nil)
            // A new copy is staged in the same folder; the old one's sizes and release go.
            await record("job \(id)'s import ledger couldn't be forgotten") {
                try LibraryIndex(at: database).forgetImportJob(id)
            }
            return false
        }
    }

    private func miss(_ job: AutoUpgradeJob, _ database: URL) async {
        unrecorded.remove(job)
        let at = now().timeIntervalSince1970
        await record("job \(job.jobID)'s miss couldn't be counted") {
            let miss = try LibraryIndex(at: database).recordUpgradeMiss(job, at: at)
            let aside = miss.isSetAside ? "; set aside" : ""
            logger.notice("release \(job.releaseID) missed \(miss.misses) times\(aside)")
        }
    }

    /// Runs `write` on the index off the main thread; false, logged with `failure`, when it
    /// threw.
    @discardableResult
    private func record(_ failure: String, _ write: @escaping @Sendable () throws -> Void) async
        -> Bool
    {
        let result = await blockingFileWork { Result { try write() } }
        do {
            try result.get()
            return true
        } catch {
            logger.error("\(failure): \(error)")
            return false
        }
    }

    /// Queues `candidate` as a FLAC upgrade and records it as this Mac's; false when the
    /// service didn't answer, or the index didn't record it, which ends the pass. A job the
    /// index didn't record is kept as this Mac's, to record at the next pass.
    private func queue(_ candidate: UpgradeCandidate, _ session: Session, epoch: String) async
        -> Bool
    {
        let release = candidate.releaseID
        let snapshot: ReleaseSnapshot
        do {
            snapshot = try await releaseSnapshot(release, session.setup.catalog)
        } catch {
            logger.error("release \(release) can't be upgraded automatically: \(error)")
            unqueueable.insert(release)
            return true
        }
        guard goesOn(session, epoch) else { return false }
        let order = JobOrder.upgrade(
            DownloadJob.Upgrade(
                currentQuality: candidate.quality, oldPaths: candidate.sharePaths), .flac)
        let job: DownloadJob
        do throws(RecommenderError) {
            job = try await session.setup.service.create(snapshot, order)
        } catch {
            if case .refused = error.kind {
                // Queued from the other Mac, or by hand, since the poll.
                logger.info("release \(release) wasn't queued automatically: \(error)")
                return true
            }
            logger.info("the automatic upgrades wait for music-recommender: \(error)")
            return false
        }
        session.model.took(job)
        logger.notice("release \(release) queued as an automatic upgrade, job \(job.id)")
        let database = session.setup.databaseURL
        let mine = AutoUpgradeJob(epoch: epoch, jobID: job.id, releaseID: release)
        let recorded = await record("job \(job.id) was queued but not recorded as automatic") {
            try LibraryIndex(at: database).recordAutoUpgradeJob(mine)
        }
        if !recorded { unrecorded.insert(mine) }
        return recorded
    }
}
