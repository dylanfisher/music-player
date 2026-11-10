import Foundation
import Testing

@testable import Discogs
@testable import Downloads
@testable import Library
@testable import Recommender

// The coordinator against the fake service and a temporary index for the outbox, with AutoTag,
// the staged writer and the import run stood in for, and every wait on the fake clock.

/// What the coordinator's stand-ins were asked to do.
private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var tagged: [StagedJob] = []
    private var written = 0
    private var events: [String] = []
    private var imported: [Int] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var holding = false

    func tag(_ job: StagedJob) {
        lock.withLock {
            tagged.append(job)
            events.append("tag")
        }
    }
    func recover() { lock.withLock { events.append("recover") } }
    private var recoveryGate: CheckedContinuation<Void, Never>?
    private var holdingRecovery = false
    /// Makes the recovery wait until `openRecovery`.
    func holdRecovery() { lock.withLock { holdingRecovery = true } }
    func waitForRecovery() async {
        await withCheckedContinuation { (wake: CheckedContinuation<Void, Never>) in
            let wait = lock.withLock {
                guard holdingRecovery else { return false }
                recoveryGate = wake
                return true
            }
            if !wait { wake.resume() }
        }
    }
    func openRecovery() {
        lock.withLock { () -> CheckedContinuation<Void, Never>? in
            holdingRecovery = false
            defer { recoveryGate = nil }
            return recoveryGate
        }?.resume()
    }
    /// What the stand-ins were asked, in order.
    var order: [String] { lock.withLock { events } }
    func write() { lock.withLock { written += 1 } }
    func run(_ id: Int) { lock.withLock { imported.append(id) } }
    var tags: [StagedJob] { lock.withLock { tagged } }
    var writes: Int { lock.withLock { written } }
    var imports: [Int] { lock.withLock { imported } }

    /// Makes the next tag run wait in AutoTag until `open`.
    func hold() { lock.withLock { holding = true } }
    var isHeld: Bool { lock.withLock { gate != nil } }

    func waitIfHeld() async {
        await withCheckedContinuation { (wake: CheckedContinuation<Void, Never>) in
            let wait = lock.withLock {
                guard holding else { return false }
                holding = false
                gate = wake
                return true
            }
            if !wait { wake.resume() }
        }
    }

    func open() {
        lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { gate = nil }
            return gate
        }?.resume()
    }
}

/// An AutoTag run with `verdict` and no files, as AutoTag reports one.
private func run(_ verdict: AutoTagRun.Verdict, for job: StagedJob, root: String = "/nonexistent")
    -> AutoTagRun
{
    AutoTagRun(
        verdict: verdict, staged: StagedAlbum(job, stagingRoot: root), match: nil, changes: nil,
        edits: [])
}

/// Appends bytes to each of `job`'s files under `root`, as a tag write does when its padding
/// runs out.
private func grow(_ job: StagedJob, under root: String) {
    for file in job.files {
        let path = root + "/" + job.folder + "/" + file.name
        guard let handle = FileHandle(forWritingAtPath: path) else { continue }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("grown".utf8))
        try? handle.close()
    }
}

/// A coordinator on a fresh index, for `service`.
private final class Setup {
    let service: FakeService
    let calls = Calls()
    let databaseURL: URL
    var verdict = AutoTagRun.Verdict.clean
    /// The staging folder the stand-ins read and write, where `stage` puts files.
    let stagingRoot: String
    /// What the staged journal's recovery reports as failed.
    var recoveryProblems: [String] = []
    /// What the stand-in import run does to the outbox, as ImportRun queues its reports.
    var importReports: [HandoffEvent] = [.approved, .importing, .imported]

    init(_ jobs: [DownloadJob] = []) throws {
        service = FakeService(jobs)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "downloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        databaseURL = folder.appendingPathComponent("library.sqlite", isDirectory: false)
        stagingRoot = folder.path + "/staging"
        _ = try LibraryIndex(at: databaseURL)
    }

    /// Puts the files of job `id`'s folder in the staging folder, each with `bytes` bytes.
    func stage(_ id: Int, bytes: Int = 100) throws {
        let folder = stagingRoot + "/job-\(id)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for name in ["01 First Song.flac", "02 Second Song.flac"] {
            try Data(count: bytes).write(to: URL(fileURLWithPath: folder + "/" + name))
        }
    }

    var index: LibraryIndex { get throws { try LibraryIndex(at: databaseURL) } }

    func coordinator(catalog: Bool = true, failingAfterClaim: Int = 0) -> DownloadsCoordinator {
        let calls = calls
        let verdict = verdict
        let clock = service.clock
        let reports = importReports
        let url = databaseURL
        let service = service
        let root = stagingRoot
        let recovery = recoveryProblems
        return DownloadsCoordinator(
            machine: FakeService.machine, databaseURL: url,
            effects: DownloadsCoordinator.Effects(
                service: service.service, sleep: { try await clock.sleep($0) },
                autoTag: catalog
                    ? { @Sendable job in
                        calls.tag(job)
                        await calls.waitIfHeld()
                        return run(verdict, for: job, root: root)
                    } : nil,
                recover: {
                    calls.recover()
                    await calls.waitForRecovery()
                    return recovery
                },
                write: { run in
                    calls.write()
                    if let job = calls.tags.last { grow(job, under: root) }
                    return run.verdict
                },
                importRun: { job, deliver in
                    calls.run(job.jobID)
                    if calls.imports.count == 1 { service.failHandoffs(failingAfterClaim) }
                    do {
                        let index = try LibraryIndex(at: url)
                        for event in reports {
                            if try !index.importReports().contains(where: { $0.body == event.json })
                            {
                                _ = try index.queueImportReport(
                                    job: job.jobID, release: job.releaseID, body: event.json)
                            }
                            // ImportRun hears the service before the first rename.
                            if event == .importing, let why = await deliver() {
                                return .refused(why)
                            }
                        }
                        try index.recordImportStep(
                            ImportStep(
                                jobID: job.jobID, releaseID: job.releaseID, kind: .moved,
                                path: "job-\(job.jobID)/01 First Song.flac",
                                destination: "library/A/01 First Song.flac", sizeBytes: 1))
                    } catch {
                        return .refused("\(error)")
                    }
                    return .imported(["library/A/01 First Song.flac"])
                }))
    }

    func outbox() throws -> [String] {
        try index.importReports().map { type(try HandoffEvent(json: $0.body)) }
    }

    func ledger(_ id: Int) throws -> [ImportStep] { try index.importSteps(job: id) }
}

private func approved(_ id: Int) -> ApprovedImport {
    ApprovedImport(
        jobID: id, releaseID: 4242, state: .staged, folder: "job-\(id)",
        files: [DownloadJob.File(name: "01 First Song.flac", sizeBytes: 1, position: "1")],
        upgrade: nil)
}

private let clean = DownloadJob.Tagging(status: .clean, reasons: [])

@Test(arguments: [
    (JobState.staged, DownloadJob.Tagging.Status.none, nil as String?, true),
    // A run that crashed leaves `running` with no live lease.
    (.staged, .running, nil, true),
    (.staged, .running, "Kitchen", false),
    (.staged, .none, "Kitchen", false),
    (.staged, .none, "Studio", false),
    (.staged, .clean, nil, false),
    (.staged, .discrepancy, nil, false),
    (.staged, .error, nil, false),
    (.downloaded, .none, nil, false),
    (.approved, .none, nil, false),
])
func aStagedJobIsTaggedWhenNoRunHoldsIt(
    state: JobState, tagging: DownloadJob.Tagging.Status, lease: String?, tags: Bool
) {
    let one = job(1, state) {
        $0.tagging = DownloadJob.Tagging(status: tagging, reasons: [])
        $0.lease = lease.map { DownloadJob.Hold(machine: $0, expiresAt: 1_794_100_600) }
    }
    #expect(DownloadsCoordinator.needsTagging(one) == tags)
}

@Test func aCleanRunIsWrittenAndReportedUnderTheLease() async throws {
    let setup = try Setup([job(1)])
    await setup.coordinator().take([job(1)])
    #expect(
        setup.service.eventTypes == ["lease", "tagging running", "tagging clean", "release_lease"])
    #expect(setup.calls.writes == 1)
    #expect(setup.calls.tags.map(\.folder) == ["job-1"])
    #expect(
        setup.calls.tags.first?.files.map(\.name) == ["01 First Song.flac", "02 Second Song.flac"])
    #expect(try setup.outbox().isEmpty)
    let after = try #require(setup.service.job(1))
    #expect(after.tagging == clean)
    #expect(after.lease == nil)
}

@Test func aDiscrepancyIsReportedAndWritesNothing() async throws {
    let setup = try Setup([job(1)])
    setup.verdict = .discrepancy(["track 2 is 40 s off"])
    await setup.coordinator().take([job(1)])
    #expect(setup.calls.writes == 0)
    #expect(
        setup.service.job(1)?.tagging
            == DownloadJob.Tagging(status: .discrepancy, reasons: ["track 2 is 40 s off"]))
    #expect(setup.service.eventTypes.last == "release_lease")
}

@Test func aMacWithNoCatalogDoesntTag() async throws {
    let setup = try Setup([job(1)])
    await setup.coordinator(catalog: false).take([job(1)])
    #expect(setup.service.events.isEmpty)
}

@Test func aLeaseAnotherMacTookFirstIsLeftAlone() async throws {
    // The list said no one held it; by the time this Mac asks, the kitchen's Mac does.
    let setup = try Setup([
        job(1) { $0.lease = DownloadJob.Hold(machine: "Kitchen", expiresAt: 1_794_100_600) }
    ])
    let coordinator = setup.coordinator()
    await coordinator.take([job(1)])
    #expect(setup.service.eventTypes == ["lease"])
    #expect(setup.calls.tags.isEmpty)
    #expect(setup.calls.writes == 0)
    // Listed as held, it isn't asked for at all.
    await coordinator.take([try #require(setup.service.job(1))])
    #expect(setup.service.eventTypes == ["lease"])
}

@Test func aRunThatCrashedMidLeaseIsTakenOverAtTheNextLaunch() async throws {
    // A run on this Mac reported `running` and quit with the lease still live.
    let crashed = job(1) {
        $0.tagging = DownloadJob.Tagging(status: .running, reasons: [])
        $0.lease = DownloadJob.Hold(machine: FakeService.machine, expiresAt: 1_794_100_600)
    }
    let setup = try Setup([crashed])
    await setup.coordinator().take([try #require(setup.service.job(1))])
    #expect(
        setup.service.eventTypes == [
            "release_lease", "lease", "tagging running", "tagging clean", "release_lease",
        ])
    #expect(setup.calls.tags.count == 1)
    #expect(setup.service.job(1)?.tagging == clean)
}

@Test func aLeaseThatExpiredAfterACrashIsTaggedAgainOnAnyMac() async throws {
    let setup = try Setup([
        job(1) {
            $0.tagging = DownloadJob.Tagging(status: .running, reasons: [])
            $0.lease = DownloadJob.Hold(machine: "Kitchen", expiresAt: 1_794_100_600)
        }
    ])
    let coordinator = setup.coordinator()
    await coordinator.take([try #require(setup.service.job(1))])
    #expect(setup.service.events.isEmpty)
    setup.service.clock.advance(by: 601)
    await coordinator.take([try #require(setup.service.job(1))])
    #expect(setup.service.eventTypes.first == "lease")
    #expect(setup.service.job(1)?.tagging == clean)
}

@Test func theLeaseIsRenewedEveryThreeMinutesAndALostOneWritesNothing() async throws {
    let setup = try Setup([job(1)])
    let clock = setup.service.clock
    setup.calls.hold()
    let coordinator = setup.coordinator()
    let tagging = Task { await coordinator.take([job(1)]) }
    await eventually("AutoTag running, the renewal waiting") {
        setup.calls.isHeld && clock.waiting == [180]
    }
    clock.advance(by: 180)
    await eventually("a renewal") { setup.service.eventTypes.count == 3 }
    #expect(setup.service.eventTypes == ["lease", "tagging running", "lease"])

    // The Mac slept past the lease, and the kitchen's Mac took the job over.
    var taken = try #require(setup.service.job(1))
    taken.lease = DownloadJob.Hold(machine: "Kitchen", expiresAt: Int(clock.now) + 600)
    setup.service.put(taken)
    await eventually("the next renewal waiting") { clock.waiting == [180] }
    clock.advance(by: 180)
    await eventually("a refused renewal") { setup.service.eventTypes.count == 4 }
    setup.calls.open()
    await tagging.value
    #expect(setup.calls.writes == 0)
    #expect(setup.service.eventTypes == ["lease", "tagging running", "lease", "lease"])
    #expect(try setup.outbox().isEmpty)
    #expect(clock.waiting.isEmpty)
}

@Test func anApprovalTheServiceDoesntAnswerMovesNothingAndRunsAgainOnceItDoes() async throws {
    let setup = try Setup([job(1) { $0.tagging = clean }])
    // `approved` goes out before anything moves, and the service doesn't answer it.
    let first = await setup.coordinator(failingAfterClaim: 1).approve(approved(1))
    #expect(first == .refused("music-recommender didn't answer; nothing was moved"))
    #expect(try setup.ledger(1).isEmpty)
    // The send after the run delivered them, so the job is importing, and a run goes on.
    #expect(try setup.outbox().isEmpty)
    #expect(setup.service.job(1)?.state == .importing)

    setup.importReports = [.importing, .imported]
    var again = approved(1)
    again.state = .importing
    let outcome = await setup.coordinator().approve(again)
    #expect(outcome == .imported(["library/A/01 First Song.flac"]))
    #expect(setup.service.job(1)?.state == .imported)
    #expect(try setup.ledger(1).isEmpty)
}

@Test func aReportTheServiceRefusesIsDroppedAndSaid() async throws {
    // Approved with no clean tagging: the service refuses it, and the rest still go.
    let setup = try Setup([job(1)])
    for event in [HandoffEvent.approved, .importing] {
        _ = try setup.index.queueImportReport(job: 1, release: 4242, body: event.json)
    }
    let coordinator = setup.coordinator()
    #expect(await coordinator.flush())
    #expect(setup.service.eventTypes == ["approved", "importing"])
    #expect(try setup.outbox().isEmpty)
    let problems = await coordinator.problems
    #expect(problems.count == 2)
    #expect(problems.first?.contains("job 1's approved report") == true)
}

@Test func aJobTaggedSinceThePollIsNotApprovedUntilItsClean() async throws {
    // The window showed a clean job, but the service has it untagged now.
    let setup = try Setup([job(1)])
    let outcome = await setup.coordinator().approve(approved(1))
    #expect(outcome == .refused("the job is staged, tagged none, not clean"))
    #expect(setup.calls.imports.isEmpty)
    #expect(setup.service.eventTypes == ["claim", "release"])
    #expect(setup.service.job(1)?.review == nil)
}

@Test func aJobAnotherMacApprovedSinceThePollIsNotApprovedAgain() async throws {
    let setup = try Setup([job(1, .approved) { $0.tagging = clean }])
    let outcome = await setup.coordinator().approve(approved(1))
    #expect(outcome == .refused("the job is approved, not staged"))
    #expect(setup.calls.imports.isEmpty)
}

@Test func aJobTaggedByAnotherMacSinceThePollIsNotTaggedAgain() async throws {
    // The poll saw it untagged; by the time this Mac leases it, the other Mac finished.
    let setup = try Setup([job(1) { $0.tagging = clean }])
    await setup.coordinator().take([job(1)])
    #expect(setup.calls.tags.isEmpty)
    #expect(setup.calls.writes == 0)
    #expect(setup.service.eventTypes == ["lease", "release_lease"])
}

@Test func resumeHereTakesTheClaimOverFromAnotherMac() async throws {
    let left = job(1, .importing) {
        $0.tagging = clean
        $0.review = DownloadJob.Hold(machine: "Kitchen", expiresAt: 1_794_150_000)
    }
    let setup = try Setup([left])
    setup.importReports = [.importing, .imported]
    let coordinator = setup.coordinator()
    var resumed = approved(1)
    resumed.state = .importing

    let refused = await coordinator.approve(resumed)
    guard case .refused(let why) = refused else {
        Issue.record("\(refused)")
        return
    }
    #expect(why.contains("claimed"))
    #expect(setup.calls.imports.isEmpty)

    let outcome = await coordinator.resumeHere(resumed)
    #expect(outcome == .imported(["library/A/01 First Song.flac"]))
    #expect(setup.calls.imports == [1])
    #expect(
        setup.service.eventTypes == ["claim", "claim take_over", "importing", "imported"])
    #expect(setup.service.job(1)?.state == .imported)
    #expect(try setup.ledger(1).isEmpty)
}

@Test func theReviewClaimIsTakenAndGivenUp() async throws {
    let setup = try Setup([job(1) { $0.tagging = clean }])
    let coordinator = setup.coordinator()
    let claimed = try await coordinator.claimReview(1)
    #expect(claimed.review?.machine == FakeService.machine)
    #expect(claimed.review?.expiresAt == Int(setup.service.clock.now) + 86_400)
    let released = try await coordinator.releaseReview(1)
    #expect(released.review == nil)
}

@Test func rejectClaimsAndReportsThroughTheOutbox() async throws {
    let setup = try Setup([job(1)])
    let problem = await setup.coordinator().reject(try #require(setup.service.job(1)))
    #expect(problem == nil)
    #expect(setup.service.eventTypes == ["claim", "rejected"])
    #expect(setup.service.job(1)?.state == .rejected)
}

@Test func aResolvedDiscrepancyIsReportedCleanUnderALease() async throws {
    let setup = try Setup([
        job(1) {
            $0.tagging = DownloadJob.Tagging(status: .discrepancy, reasons: ["a bonus track"])
        }
    ])
    let problem = await setup.coordinator().resolved(
        try #require(setup.service.job(1)), .clean, release: 4242, stagingRoot: setup.stagingRoot)
    #expect(problem == nil)
    #expect(setup.service.eventTypes == ["lease", "tagging clean", "release_lease"])
    #expect(setup.service.job(1)?.tagging == clean)
}

private let firstSizes = ["01 First Song.flac": 105, "02 Second Song.flac": 105]

@Test func aCleanWriteRecordsWhatTheFilesMeasureAfterIt() async throws {
    let setup = try Setup([job(1)])
    try setup.stage(1)
    await setup.coordinator().take([job(1)])
    #expect(setup.calls.writes == 1)
    #expect(try setup.index.stagedSizes(job: 1, folder: "job-1") == firstSizes)
}

@Test func theRecordedSizesGoToTheNextTagRun() async throws {
    let setup = try Setup([job(1)])
    try setup.stage(1)
    try setup.index.recordStagedSizes(job: 1, release: 4242, folder: "job-1", sizes: firstSizes)
    await setup.coordinator().take([job(1)])
    #expect(setup.calls.tags.first?.tagged == firstSizes)
    #expect(await setup.coordinator().stagedJob(job(1))?.tagged == firstSizes)
}

@Test func aDiscrepancyRecordsNothing() async throws {
    let setup = try Setup([job(1)])
    setup.verdict = .discrepancy(["a bonus track"])
    try setup.stage(1)
    await setup.coordinator().take([job(1)])
    #expect(try setup.index.stagedSizes(job: 1, folder: "job-1") == [:])
}

@Test func aResolvedDiscrepancyRecordsWhatTheTaggerLeftTheFilesAt() async throws {
    let setup = try Setup([
        job(1) {
            $0.tagging = DownloadJob.Tagging(status: .discrepancy, reasons: ["a bonus track"])
        }
    ])
    try setup.stage(1, bytes: 250)
    let problem = await setup.coordinator().resolved(
        try #require(setup.service.job(1)), .clean, release: 4242, stagingRoot: setup.stagingRoot)
    #expect(problem == nil)
    #expect(
        try setup.index.stagedSizes(job: 1, folder: "job-1")
            == ["01 First Song.flac": 250, "02 Second Song.flac": 250])
}

@Test func theStagedJournalIsRecoveredOnceBeforeTheFirstTagRun() async throws {
    let setup = try Setup([job(1), job(2)])
    let coordinator = setup.coordinator()
    await coordinator.take([job(1)])
    await coordinator.take([job(2)])
    #expect(setup.calls.order == ["recover", "tag", "tag"])
}

@Test func aPollThatOverlapsTheRecoveryWaitsForItBeforeTagging() async throws {
    let setup = try Setup([job(1), job(2)])
    setup.calls.holdRecovery()
    let coordinator = setup.coordinator()
    let first = Task { await coordinator.take([job(1)]) }
    await eventually("the recovery started") { setup.calls.order.contains("recover") }
    let second = Task { await coordinator.take([job(2)]) }
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(setup.calls.order == ["recover"], "no job is tagged while the recovery runs")
    setup.calls.openRecovery()
    await first.value
    await second.value
    #expect(setup.calls.order.first == "recover")
    #expect(setup.calls.order.contains("tag"))
}

@Test func anOlderPollNeverReplacesNewerStates() async throws {
    let setup = try Setup()
    let coordinator = setup.coordinator(catalog: false)
    await coordinator.take([job(1, .imported, revision: 5)])
    await coordinator.take([job(1, .staged, revision: 3), job(2, revision: 2)])
    #expect(await coordinator.states[1]?.state == .imported)
    #expect(await coordinator.states[2]?.state == .staged)
}

@Test func aMacWithNoCatalogLeavesTheStagedJournalAlone() async throws {
    let setup = try Setup([job(1)])
    await setup.coordinator(catalog: false).take([job(1)])
    #expect(setup.calls.order.isEmpty)
}

@Test func aRecoveryThatFailedIsSaid() async throws {
    let setup = try Setup([job(1)])
    setup.recoveryProblems = ["01.flac couldn't be put back"]
    let coordinator = setup.coordinator()
    await coordinator.take([job(1)])
    #expect(await coordinator.problems.first == "01.flac couldn't be put back")
}

@Test func anIdlePollNeverLooksAtTheOutbox() async throws {
    let setup = try Setup([job(1) { $0.tagging = clean }])
    let coordinator = setup.coordinator()
    await coordinator.take([job(1) { $0.tagging = clean }])
    #expect(await coordinator.outboxReads == 1, "the first poll finds what a run before left")
    await coordinator.take([job(1) { $0.tagging = clean }])
    await coordinator.take([job(1) { $0.tagging = clean }])
    #expect(await coordinator.outboxReads == 1)
}

@Test func anOutboxThatWasntEmptiedIsLookedAtAgainAndOneWithNothingIsNot() async throws {
    let setup = try Setup([job(1) { $0.tagging = clean }])
    _ = try setup.index.queueImportReport(job: 1, release: 4242, body: HandoffEvent.release.json)
    let coordinator = setup.coordinator()
    setup.service.failHandoffs(1)
    await coordinator.take([])
    await coordinator.take([])
    #expect(await coordinator.outboxReads == 2, "the first send failed, so the next poll sends")
    #expect(try setup.outbox().isEmpty)
    await coordinator.take([])
    #expect(await coordinator.outboxReads == 2)
}

@Test func anImportedReportRefusedBecauseTheJobIsImportedAlreadyForgetsTheLedger() async throws {
    // Another Mac finished the import and holds the claim now, so the repeat is refused.
    let imported = job(1, .imported) {
        $0.tagging = clean
        $0.review = DownloadJob.Hold(machine: "Kitchen", expiresAt: 1_794_150_000)
    }
    let setup = try Setup([imported])
    try setup.index.recordImportStep(
        ImportStep(
            jobID: 1, releaseID: 4242, kind: .moved, path: "job-1/01 First Song.flac",
            destination: "library/A/01 First Song.flac", sizeBytes: 1))
    _ = try setup.index.queueImportReport(job: 1, release: 4242, body: HandoffEvent.imported.json)
    let coordinator = setup.coordinator()
    await coordinator.take([imported])
    #expect(try setup.outbox().isEmpty)
    #expect(try setup.ledger(1).isEmpty)
    #expect(await coordinator.problems.isEmpty, "expected, so nothing to tell the owner")
}

@Test func anImportedReportRefusedForAJobNotImportedKeepsTheLedger() async throws {
    let setup = try Setup([job(1, .approved) { $0.tagging = clean }])
    try setup.index.recordImportStep(
        ImportStep(
            jobID: 1, releaseID: 4242, kind: .moved, path: "job-1/01 First Song.flac",
            destination: "library/A/01 First Song.flac", sizeBytes: 1))
    _ = try setup.index.queueImportReport(job: 1, release: 4242, body: HandoffEvent.imported.json)
    let coordinator = setup.coordinator()
    await coordinator.take([try #require(setup.service.job(1))])
    #expect(try setup.outbox().isEmpty)
    #expect(try setup.ledger(1).count == 1, "a resume still needs it")
    #expect(await coordinator.problems.count == 1)
}

/// The service can't record a job's new release yet, so the index keeps it (ADR 0178): the
/// next tagger or tag run of the job tags with it, and tagging back as the queued release
/// forgets it.
@Test func aResolvedJobTaggedAsAnotherReleaseKeepsItHere() async throws {
    let setup = try Setup([
        job(1) {
            $0.tagging = DownloadJob.Tagging(status: .discrepancy, reasons: ["a bonus track"])
        }
    ])
    try setup.stage(1)
    let coordinator = setup.coordinator()
    let listed = try #require(setup.service.job(1))
    #expect(await coordinator.stagedJob(listed)?.releaseID == 4242)
    let problem = await coordinator.resolved(
        listed, .clean, release: 5151, stagingRoot: setup.stagingRoot)
    #expect(problem == nil)
    #expect(setup.service.eventTypes == ["lease", "tagging clean", "release_lease"])
    #expect(await coordinator.taggedAs() == [1: TaggedRelease(folder: "job-1", releaseID: 5151)])
    #expect(await coordinator.stagedJob(listed)?.releaseID == 5151)
    #expect(
        await setup.coordinator().taggedAs() == [
            1: TaggedRelease(folder: "job-1", releaseID: 5151)
        ],
        "kept in the index, for the next launch")

    _ = await coordinator.resolved(listed, .clean, release: 4242, stagingRoot: setup.stagingRoot)
    #expect(await coordinator.taggedAs().isEmpty)
    #expect(await coordinator.stagedJob(listed)?.releaseID == 4242)
}
