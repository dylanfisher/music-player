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
        /// Finishes the writes a crash left unconfirmed in the staged journal (ADR 0146),
        /// giving the failures; the first tag run after launch waits for it.
        var recover: @Sendable () async -> [String]
        /// Writes a clean run's edits through `StagedWriter` and reads them back, returning
        /// the verdict to report.
        var write: @Sendable (AutoTagRun) async -> AutoTagRun.Verdict
        /// `ImportRun.run`, with the trash and the watcher's moves and rescan in it. The second
        /// argument sends the outbox and says why it couldn't: the run calls it once it has
        /// queued `approved` and `importing`, before the first rename.
        var importRun:
            @Sendable (ApprovedImport, @escaping @Sendable () async -> String?) async
                -> ImportOutcome
    }

    /// This Mac's name, as the service knows it.
    let machine: String
    private let effects: Effects
    private let databaseURL: URL
    /// Opened on first use, here, since an index belongs to the thread that uses it.
    private var opened: LibraryIndex?
    private var releasedStaleLeases = false
    /// The one recovery of the staged journal, started by the first tag-capable poll; every
    /// poll waits for it, so none tags a job while a torn file is still being put back.
    private var recovery: Task<Void, Never>?
    /// The state each job had at the newest poll that listed it, with the revision that gave it.
    /// Polls run at once, so an older one never replaces a newer.
    private(set) var states: [Int: (revision: Int, state: JobState)] = [:]
    /// Whether the outbox may hold a report: at launch, which finds what a run before left, then
    /// after a report is queued or a send wasn't answered. A poll with none doesn't look.
    private var outboxMayHold = true
    /// How many times the outbox was read to send it.
    private(set) var outboxReads = 0
    /// The job being tagged; one at a time.
    private var tagging: Int?
    /// The jobs whose lease a renewal found another Mac holding.
    private var lostLeases: Set<Int> = []
    /// The outbox send in progress; another waits for it, then sends what is left.
    private var sending: Task<Bool, Never>?
    /// The reports the service refused in the sends since `deliver` last looked.
    private var refused: [(jobID: Int, name: String, why: String)] = []
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
        for job in jobs where job.revision >= (states[job.id]?.revision ?? job.revision) {
            states[job.id] = (job.revision, job.state)
        }
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
        if outboxMayHold { await flush() }
        guard let autoTag = effects.autoTag else { return }
        let recovering: Task<Void, Never>
        if let recovery {
            recovering = recovery
        } else {
            recovering = Task { [self] in
                for problem in await effects.recover() { note(problem) }
            }
            recovery = recovering
        }
        await recovering.value
        for job in jobs.sorted(by: { $0.id < $1.id }) where Self.needsTagging(job) {
            guard tagging == nil else { return }
            await tag(job, with: autoTag)
        }
    }

    private func tag(
        _ listed: DownloadJob, with autoTag: @Sendable (StagedJob) async throws -> AutoTagRun
    ) async {
        tagging = listed.id
        defer { tagging = nil }
        let job: DownloadJob
        do {
            job = try await effects.service.handoff(listed.id, .lease)
        } catch {
            // Another Mac took it first, or the service didn't answer: the next poll says.
            logger.info("job \(listed.id) not tagged here: \(error)")
            return
        }
        // The poll may be old: the job is the service's answer now, which another Mac may have
        // tagged, or the owner rejected, since.
        guard job.state == .staged, [.none, .running].contains(job.tagging.status) else {
            logger.info(
                "job \(job.id) is \(job.state.rawValue), tagged \(job.tagging.status.rawValue); not tagged here"
            )
            await releaseLease(job.id)
            return
        }
        lostLeases.remove(job.id)
        queue(.tagging(DownloadJob.Tagging(status: .running, reasons: [])), job)
        await flush()
        let renewal = Task { await renewLease(job.id) }
        defer { renewal.cancel() }

        let verdict: AutoTagRun.Verdict
        if let staged = stagedJob(job) {
            do {
                let run = try await autoTag(staged)
                guard !lostLeases.contains(job.id) else { return }
                if run.verdict == .clean {
                    verdict = await effects.write(run)
                    // The write can grow a file, so what the files measure now is recorded
                    // whatever it reported: the checks after it hold the files to these sizes.
                    recordSizes(of: staged, under: run.staged.stagingRoot, job)
                } else {
                    verdict = run.verdict
                }
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

    /// `job` as AutoTag and the tagger take it, with the sizes its files have had since a tag
    /// write here; nil until the service has staged it.
    func stagedJob(_ job: DownloadJob) -> StagedJob? {
        guard var staged = StagedJob(job) else { return nil }
        do {
            staged.tagged = try index().stagedSizes(job: job.id, folder: staged.folder)
        } catch {
            note("job \(job.id)'s recorded file sizes couldn't be read: \(error)")
        }
        return staged
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
    /// answered, or refused because the job is imported already, the job's ledger is
    /// forgotten. A flush that finds one running waits for it, then sends what is left. True
    /// when the outbox was emptied.
    @discardableResult
    func flush() async -> Bool {
        while let running = sending { _ = await running.value }
        let task = Task { () -> Bool in
            let emptied = await sendOutbox()
            sending = nil
            return emptied
        }
        sending = task
        return await task.value
    }

    /// Sends the outbox for an import about to move files, and says why the service wouldn't
    /// have it: it refused one of the job's reports, or didn't answer. Nil when the job's
    /// reports were all answered.
    func deliver(_ id: Int) async -> String? {
        refused.removeAll { $0.jobID == id }
        // The run queued its reports through an index of its own.
        outboxMayHold = true
        await flush()
        if let refusal = refused.first(where: { $0.jobID == id }) {
            return "music-recommender refused \(refusal.name): \(refusal.why)"
        }
        do {
            guard try index().importReports().contains(where: { $0.jobID == id }) else {
                return nil
            }
        } catch {
            return "the outbox couldn't be read: \(error)"
        }
        return "music-recommender didn't answer; nothing was moved"
    }

    private func sendOutbox() async -> Bool {
        outboxReads += 1
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
            var importedAlready = false
            do {
                _ = try await effects.service.handoff(report.jobID, event)
            } catch {
                switch error.kind {
                case .refused(let refusal)
                where event == .imported
                    && (refusal.state == JobState.imported.rawValue
                        || states[report.jobID]?.state == .imported):
                    // Another Mac finished the job: this Mac's ledger has nothing left to resume.
                    importedAlready = true
                    logger.info("job \(report.jobID) was imported already; its ledger is dropped")
                case .refused, .badRequest:
                    delivered = false
                    note("job \(report.jobID)'s \(event.name) report was refused: \(error)")
                    refused.append((report.jobID, event.name, "\(error)"))
                default:
                    logger.info("the outbox waits for music-recommender: \(error)")
                    return false
                }
            }
            guard remove(report) else { return false }
            if event == .imported, delivered || importedAlready {
                do {
                    try index().forgetImportJob(report.jobID)
                } catch {
                    note("job \(report.jobID)'s import ledger couldn't be forgotten: \(error)")
                }
            }
        }
        outboxMayHold = false
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
            outboxMayHold = true
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

    /// Why `claimed`, the service's answer to the claim, can't be imported as the sheet showed
    /// it: an approval needs it staged and clean, a resume needs it approved or importing.
    private static func stale(_ claimed: DownloadJob, for job: ApprovedImport, takingOver: Bool)
        -> String?
    {
        if takingOver || job.state != .staged {
            guard [.approved, .importing].contains(claimed.state) else {
                return "the job is \(claimed.state.rawValue), not approving"
            }
            return nil
        }
        guard claimed.state == .staged else {
            return "the job is \(claimed.state.rawValue), not staged"
        }
        guard claimed.tagging.status == .clean else {
            return "the job is staged, tagged \(claimed.tagging.status.rawValue), not clean"
        }
        return nil
    }

    private func runImport(_ job: ApprovedImport, takingOver: Bool) async -> ImportOutcome {
        guard !importing else { return .refused("another import is running") }
        importing = true
        defer { importing = false }
        let claimed: DownloadJob
        do {
            claimed = try await effects.service.handoff(job.jobID, .claim(takeOver: takingOver))
        } catch {
            return .refused("\(error)")
        }
        // The sheet may be old: the job is the service's answer now.
        if let stale = Self.stale(claimed, for: job, takingOver: takingOver) {
            _ = try? await effects.service.handoff(job.jobID, .release)
            return .refused(stale)
        }
        let outcome = await effects.importRun(job) { [self] in await deliver(job.jobID) }
        outboxMayHold = true
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
    /// lease of its own, after recording the sizes its writes left the files at under
    /// `stagingRoot`. Nil when reported, else why not.
    func resolved(_ job: DownloadJob, _ verdict: AutoTagRun.Verdict, stagingRoot: String) async
        -> String?
    {
        if let staged = StagedJob(job) { recordSizes(of: staged, under: stagingRoot, job) }
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

    /// Records what `staged`'s files measure under `stagingRoot` now, after a tag write.
    private func recordSizes(of staged: StagedJob, under stagingRoot: String, _ job: DownloadJob) {
        do {
            try index().recordStagedSizes(
                job: job.id, release: job.release.releaseID, folder: staged.folder,
                sizes: try staged.sizesOnDisk(stagingRoot: stagingRoot))
        } catch {
            note("job \(job.id)'s file sizes after the tag write couldn't be recorded: \(error)")
        }
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
