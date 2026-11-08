import Discogs
import Foundation
import Library
import Log
import Recommender

private let logger = moduleLogger()

/// This Mac's part of the downloads, run in the background from launch to quit (the service's
/// `docs/downloads.md`, Claims and Auto-tagging). It tags each staged job no run holds, under
/// the service's 10-minute tagging lease, renewed every 3; it writes a clean run's tags and
/// nothing else; it sends the reports the index's outbox holds, in order, until each is
/// answered; and it runs Approve's import under the 24-hour review claim. Every effect is
/// injected, the clock's waits too.
actor DownloadsCoordinator {
    /// Waits about this many seconds. Throws when cancelled.
    typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    /// How often a tag run renews its 10-minute lease.
    static let leaseRenewal: TimeInterval = 180

    struct Effects: Sendable {
        var service: DownloadsService
        var sleep: Sleep
        /// Matches a staged job's files with its release, writing nothing; nil on a Mac with
        /// no Discogs catalog, which doesn't tag.
        var autoTag: (@Sendable (StagedJob) async throws -> AutoTagRun)?
        /// Writes a clean run's edits through `StagedWriter` and reads them back, returning
        /// the verdict to report.
        var write: @Sendable (AutoTagRun) async -> AutoTagRun.Verdict
        /// `ImportRun.run`, with the trash and the watcher's moves and rescan in it.
        var importRun: @Sendable (ApprovedImport) async -> ImportOutcome
    }

    /// This Mac's name, as the service knows it.
    let machine: String
    private let effects: Effects
    private let databaseURL: URL
    /// Opened on first use, here, since an index belongs to the thread that uses it.
    private var opened: LibraryIndex?
    private var releasedStaleLeases = false
    /// The job being tagged; one at a time.
    private var tagging: Int?
    /// The jobs whose lease a renewal found another Mac holding.
    private var lostLeases: Set<Int> = []
    private var flushing = false
    private var importing = false
    /// What went wrong that no call returns: reports the service refused, which the outbox
    /// dropped, and the index's failures, for the window to show.
    private(set) var problems: [String] = []

    /// `databaseURL` is the library index's, which holds the outbox and the import ledger.
    init(machine: String, databaseURL: URL, effects: Effects) {
        self.machine = machine
        self.databaseURL = databaseURL
        self.effects = effects
    }

    /// Whether `job` is waiting for a tag run: staged, with no live lease, and either never
    /// tagged or left `running` by a run that crashed or slept past its lease, which a
    /// takeover runs again from the start.
    static func needsTagging(_ job: DownloadJob) -> Bool {
        job.state == .staged && job.lease == nil
            && (job.tagging.status == .none || job.tagging.status == .running)
    }

    /// Takes the jobs a poll found: the first time, gives up any lease this Mac still holds
    /// from before it launched; then sends the outbox, and tags the jobs waiting for it.
    func take(_ jobs: [DownloadJob]) async {
        var jobs = jobs
        if !releasedStaleLeases {
            releasedStaleLeases = true
            for (offset, job) in jobs.enumerated() where job.lease?.machine == machine {
                do {
                    jobs[offset] = try await effects.service.handoff(job.id, .releaseLease)
                } catch {
                    note("job \(job.id)'s stale lease couldn't be given up: \(error)")
                }
            }
        }
        await flush()
        guard let autoTag = effects.autoTag else { return }
        for job in jobs.sorted(by: { $0.id < $1.id }) where Self.needsTagging(job) {
            guard tagging == nil else { return }
            await tag(job, with: autoTag)
        }
    }

    private func tag(
        _ job: DownloadJob, with autoTag: @Sendable (StagedJob) async throws -> AutoTagRun
    ) async {
        tagging = job.id
        defer { tagging = nil }
        do {
            _ = try await effects.service.handoff(job.id, .lease)
        } catch {
            // Another Mac took it first, or the service didn't answer: the next poll says.
            logger.info("job \(job.id) not tagged here: \(error)")
            return
        }
        lostLeases.remove(job.id)
        queue(.tagging(DownloadJob.Tagging(status: .running, reasons: [])), job)
        await flush()
        let renewal = Task { await renewLease(job.id) }
        defer { renewal.cancel() }

        let verdict: AutoTagRun.Verdict
        if let staged = StagedJob(job) {
            do {
                let run = try await autoTag(staged)
                guard !lostLeases.contains(job.id) else { return }
                verdict = run.verdict == .clean ? await effects.write(run) : run.verdict
            } catch {
                verdict = .error(["\(error)"])
            }
        } else {
            verdict = .error(["the service listed the job with no staged folder or format"])
        }
        renewal.cancel()
        guard !lostLeases.contains(job.id) else { return }
        queue(.tagging(Self.tagging(verdict)), job)
        await flush()
        await releaseLease(job.id)
    }

    /// Renews the lease every 3 minutes until cancelled, or until the service says another
    /// Mac holds it, which stops the run before it writes.
    private func renewLease(_ id: Int) async {
        while true {
            do {
                try await effects.sleep(Self.leaseRenewal)
            } catch {
                return
            }
            do {
                _ = try await effects.service.handoff(id, .lease)
            } catch {
                if case .refused = error.kind {
                    lostLeases.insert(id)
                    note("job \(id)'s lease went to another Mac mid-run; nothing was written")
                    return
                }
                // Unanswered: the lease holds 10 minutes, so the next renewal can still keep it.
                logger.info("job \(id)'s lease not renewed: \(error)")
            }
        }
    }

    private func releaseLease(_ id: Int) async {
        do {
            _ = try await effects.service.handoff(id, .releaseLease)
        } catch {
            // It lapses in 10 minutes regardless.
            logger.info("job \(id)'s lease not given up: \(error)")
        }
    }

    static func tagging(_ verdict: AutoTagRun.Verdict) -> DownloadJob.Tagging {
        switch verdict {
        case .clean: DownloadJob.Tagging(status: .clean, reasons: [])
        case .discrepancy(let reasons): DownloadJob.Tagging(status: .discrepancy, reasons: reasons)
        case .error(let reasons): DownloadJob.Tagging(status: .error, reasons: reasons)
        }
    }

    // MARK: - The outbox

    /// Sends the outbox's reports in order, dropping each the service answers. One it refuses
    /// is dropped too, and said in `problems`; one it doesn't answer stops the sending, and it
    /// and the rest wait for the next flush, which every poll makes. Once `imported` is
    /// answered, the job's ledger is forgotten. True when the outbox was emptied.
    @discardableResult
    func flush() async -> Bool {
        guard !flushing else { return false }
        flushing = true
        defer { flushing = false }
        let reports: [QueuedImportReport]
        do {
            reports = try index().importReports()
        } catch {
            note("the outbox couldn't be read: \(error)")
            return false
        }
        for report in reports {
            let event: HandoffEvent
            do {
                event = try HandoffEvent(json: report.body)
            } catch {
                note("job \(report.jobID)'s report \(report.body) isn't an event; dropped")
                guard remove(report) else { return false }
                continue
            }
            var delivered = true
            do {
                _ = try await effects.service.handoff(report.jobID, event)
            } catch {
                switch error.kind {
                case .refused, .badRequest:
                    delivered = false
                    note("job \(report.jobID)'s \(event.name) report was refused: \(error)")
                default:
                    logger.info("the outbox waits for music-recommender: \(error)")
                    return false
                }
            }
            guard remove(report) else { return false }
            if delivered, event == .imported {
                do {
                    try index().forgetImportJob(report.jobID)
                } catch {
                    note("job \(report.jobID)'s import ledger couldn't be forgotten: \(error)")
                }
            }
        }
        return true
    }

    private func remove(_ report: QueuedImportReport) -> Bool {
        do {
            try index().removeImportReport(report.seq)
            return true
        } catch {
            note("job \(report.jobID)'s sent report couldn't be dropped from the outbox: \(error)")
            return false
        }
    }

    private func queue(_ event: HandoffEvent, _ job: DownloadJob) {
        do {
            _ = try index().queueImportReport(
                job: job.id, release: job.release.releaseID, body: event.json)
        } catch {
            note("job \(job.id)'s report couldn't be queued: \(error)")
        }
    }

    // MARK: - Review and import

    /// Takes or renews this Mac's 24-hour review claim on the job, when the owner opens its row
    /// to review it.
    func claimReview(_ id: Int) async throws(RecommenderError) -> DownloadJob {
        try await effects.service.handoff(id, .claim(takeOver: false))
    }

    func releaseReview(_ id: Int) async throws(RecommenderError) -> DownloadJob {
        try await effects.service.handoff(id, .release)
    }

    /// Runs Approve's import under this Mac's review claim, then sends its reports.
    func approve(_ job: ApprovedImport) async -> ImportOutcome {
        await runImport(job, takingOver: false)
    }

    /// Resume Here: takes the claim over from the Mac that left the job approved or
    /// importing, and runs the import's steps from where the ledger and the files say.
    func resumeHere(_ job: ApprovedImport) async -> ImportOutcome {
        await runImport(job, takingOver: true)
    }

    private func runImport(_ job: ApprovedImport, takingOver: Bool) async -> ImportOutcome {
        guard !importing else { return .refused("another import is running") }
        importing = true
        defer { importing = false }
        do {
            _ = try await effects.service.handoff(job.jobID, .claim(takeOver: takingOver))
        } catch {
            return .refused("\(error)")
        }
        let outcome = await effects.importRun(job)
        await flush()
        return outcome
    }

    /// Rejects the job under this Mac's review claim, through the outbox; the service then
    /// deletes its staged folder. Nil when done, else why not.
    func reject(_ job: DownloadJob) async -> String? {
        do {
            _ = try await effects.service.handoff(job.id, .claim(takeOver: false))
        } catch {
            return "\(error)"
        }
        queue(.rejected, job)
        return await flush() ? nil : "the rejection waits in the outbox until the service answers"
    }

    /// Reports the tagger's verdict for a discrepancy the owner resolved and applied, under a
    /// lease of its own. Nil when reported, else why not.
    func resolved(_ job: DownloadJob, _ verdict: AutoTagRun.Verdict) async -> String? {
        do {
            _ = try await effects.service.handoff(job.id, .lease)
        } catch {
            return "\(error)"
        }
        queue(.tagging(Self.tagging(verdict)), job)
        let sent = await flush()
        await releaseLease(job.id)
        return sent ? nil : "the report waits in the outbox until the service answers"
    }

    private func index() throws -> LibraryIndex {
        if let opened { return opened }
        let index = try LibraryIndex(at: databaseURL)
        opened = index
        return index
    }

    private func note(_ problem: String) {
        logger.error("\(problem)")
        problems.append(problem)
    }
}
