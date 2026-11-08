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
    private var imported: [Int] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var holding = false

    func tag(_ job: StagedJob) { lock.withLock { tagged.append(job) } }
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
private func run(_ verdict: AutoTagRun.Verdict, for job: StagedJob) -> AutoTagRun {
    AutoTagRun(
        verdict: verdict, staged: StagedAlbum(job, stagingRoot: "/nonexistent"), match: nil,
        changes: nil, edits: [])
}

/// A coordinator on a fresh index, for `service`.
private final class Setup {
    let service: FakeService
    let calls = Calls()
    let databaseURL: URL
    var verdict = AutoTagRun.Verdict.clean
    /// What the stand-in import run does to the outbox, as ImportRun queues its reports.
    var importReports: [HandoffEvent] = [.approved, .importing, .imported]

    init(_ jobs: [DownloadJob] = []) throws {
        service = FakeService(jobs)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "downloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        databaseURL = folder.appendingPathComponent("library.sqlite", isDirectory: false)
        _ = try LibraryIndex(at: databaseURL)
    }

    var index: LibraryIndex { get throws { try LibraryIndex(at: databaseURL) } }

    func coordinator(catalog: Bool = true, failingAfterImport: Int = 0) -> DownloadsCoordinator {
        let calls = calls
        let verdict = verdict
        let clock = service.clock
        let reports = importReports
        let url = databaseURL
        let service = service
        return DownloadsCoordinator(
            machine: FakeService.machine, databaseURL: url,
            effects: DownloadsCoordinator.Effects(
                service: service.service, sleep: { try await clock.sleep($0) },
                autoTag: catalog
                    ? { @Sendable job in
                        calls.tag(job)
                        await calls.waitIfHeld()
                        return run(verdict, for: job)
                    } : nil,
                write: { run in
                    calls.write()
                    return run.verdict
                },
                importRun: { job in
                    calls.run(job.jobID)
                    do {
                        let index = try LibraryIndex(at: url)
                        try index.recordImportStep(
                            ImportStep(
                                jobID: job.jobID, releaseID: job.releaseID, kind: .moved,
                                path: "job-\(job.jobID)/01 First Song.flac",
                                destination: "library/A/01 First Song.flac", sizeBytes: 1))
                        for event in reports {
                            _ = try index.queueImportReport(
                                job: job.jobID, release: job.releaseID, body: event.json)
                        }
                    } catch {
                        return .refused("\(error)")
                    }
                    service.failHandoffs(failingAfterImport)
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

@Test func anOutboxSendThatFailsIsSentAgainThenTheLedgerForgotten() async throws {
    let setup = try Setup([job(1) { $0.tagging = clean }])
    let coordinator = setup.coordinator(failingAfterImport: 1)
    let outcome = await coordinator.approve(approved(1))
    #expect(outcome == .imported(["library/A/01 First Song.flac"]))
    #expect(setup.service.eventTypes == ["claim", "approved"])
    #expect(try setup.outbox() == ["approved", "importing", "imported"])
    #expect(try setup.ledger(1).count == 1)

    #expect(await coordinator.flush())
    #expect(setup.service.eventTypes == ["claim", "approved", "approved", "importing", "imported"])
    #expect(try setup.outbox().isEmpty)
    #expect(try setup.ledger(1).isEmpty)
    #expect(setup.service.job(1)?.state == .imported)
}

@Test func aReportTheServiceRefusesIsDroppedAndSaid() async throws {
    // Approved with no clean tagging: the service refuses it, and the rest still go.
    let setup = try Setup([job(1)])
    let coordinator = setup.coordinator()
    _ = await coordinator.approve(approved(1))
    #expect(setup.service.eventTypes == ["claim", "approved", "importing", "imported"])
    #expect(try setup.outbox().isEmpty)
    let problems = await coordinator.problems
    #expect(problems.count == 3)
    #expect(problems.first?.contains("job 1's approved report") == true)
    // `imported` wasn't delivered, so the ledger stays for a resume.
    #expect(try setup.ledger(1).count == 1)
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
    let problem = await setup.coordinator().resolved(try #require(setup.service.job(1)), .clean)
    #expect(problem == nil)
    #expect(setup.service.eventTypes == ["lease", "tagging clean", "release_lease"])
    #expect(setup.service.job(1)?.tagging == clean)
}
