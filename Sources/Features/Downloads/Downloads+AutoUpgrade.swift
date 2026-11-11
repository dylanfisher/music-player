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
            let epoch = session.model.jobs.epoch
        else { return }
        guard upgrading == nil else {
            upgradeAgain = true
            return
        }
        upgradeAgain = false
        upgrading = Task {
            await upgradePass(session, share: share, epoch: epoch)
            guard self.session === session else { return }
            upgrading = nil
            if upgradeAgain { upgradeAutomatically() }
        }
    }

    /// Whether a pass may make its next call: the box still on and the session the same.
    private func goesOn(_ session: Session) -> Bool {
        autoUpgrade && self.session === session && !Task.isCancelled
    }

    private func upgradePass(_ session: Session, share: String, epoch: String) async {
        let database = session.setup.databaseURL
        let read = await blockingFileWork {
            Result { () throws -> ([AutoUpgradeJob], [Int: UpgradeMiss], Set<Int>) in
                let index = try LibraryIndex(at: database)
                return (
                    try index.autoUpgradeJobs(), try index.upgradeMisses(),
                    try index.neverUpgradeReleases()
                )
            }
        }
        let own: [AutoUpgradeJob]
        let misses: [Int: UpgradeMiss]
        let never: Set<Int>
        do {
            (own, misses, never) = try read.get()
        } catch {
            return logger.error("the automatic upgrades couldn't be read: \(error)")
        }
        let settled = AutoUpgrades.steps(
            own: own, jobs: session.model.jobs.rows, epoch: epoch, notClean: notClean)
        var inFlight = settled.inFlight
        for step in settled.steps {
            guard goesOn(session) else { return }
            if await take(step, session) { inFlight += 1 }
        }
        guard goesOn(session), inFlight < autoUpgradesInFlight else { return }
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
        let chosen = AutoUpgrades.next(
            candidates, jobs: session.model.jobs.rows.values, never: never, misses: missed,
            skipped: unqueueable, now: now(), room: autoUpgradesInFlight - inFlight)
        for candidate in chosen {
            guard goesOn(session) else { return }
            guard await queue(candidate, session, epoch: epoch) else { return }
        }
    }

    /// Takes one step; true when it couldn't end a job, which still holds its slot.
    private func take(_ step: AutoUpgrades.Step, _ session: Session) async -> Bool {
        let service = session.setup.service
        let database = session.setup.databaseURL
        switch step {
        case .forget(let job):
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
                // Ended already, by the owner or the other Mac: a miss all the same. Only an
                // illegal transition carries the job's state.
                guard case .refused(let refusal) = error.kind, refusal.state != nil else {
                    logger.info("job \(job.jobID), which found nothing, wasn't cancelled: \(error)")
                    return true
                }
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
            notClean.remove(id)
            session.model.leave(id, nil)
            // A new copy is staged in the same folder; the old one's sizes and release go.
            await record("job \(id)'s import ledger couldn't be forgotten") {
                try LibraryIndex(at: database).forgetImportJob(id)
            }
            return false
        }
    }

    private func miss(_ job: AutoUpgradeJob, _ database: URL) async {
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
    /// service didn't answer, which ends the pass.
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
        guard goesOn(session) else { return false }
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
        return await record("job \(job.id) was queued but not recorded as automatic") {
            try LibraryIndex(at: database).recordAutoUpgradeJob(
                AutoUpgradeJob(epoch: epoch, jobID: job.id, releaseID: release))
        }
    }
}
