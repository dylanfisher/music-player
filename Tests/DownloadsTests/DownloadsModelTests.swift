import Foundation
import Testing

@testable import Downloads
@testable import Recommender

// The rows' rules as tables, and the polling on a fake clock against a fake service.

@Test(arguments: [
    (JobState.queued, nil, true),
    (.searching, nil, true),
    (.notFound, nil, true),
    (.candidateFound, nil, true),
    (.downloading, nil, true),
    (.downloaded, nil, false),
    (.staged, nil, false),
    (.approved, nil, false),
    (.importing, nil, false),
    (.failed, DownloadJob.FailedStage.search, true),
    (.failed, .download, true),
    (.failed, .stage, false),
    (.failed, .tag, false),
    (.failed, .move, false),
])
func rowsAreDimmedUntilTheFilesAreDownloaded(
    state: JobState, stage: DownloadJob.FailedStage?, dimmed: Bool
) {
    let style = DownloadRow.style(state, failedStage: stage, tagging: .none, answering: true)
    #expect(style.isDimmed == dimmed)
    #expect(style.isFailed == (state == .failed))
    // A service that doesn't answer dims them all.
    #expect(DownloadRow.style(state, failedStage: stage, tagging: .none, answering: false).isDimmed)
}

@Test(arguments: [
    (DownloadJob.Tagging.Status.none, false),
    (.running, false),
    (.clean, false),
    (.discrepancy, true),
    (.error, true),
])
func onlyTheTaggingCellWarns(tagging: DownloadJob.Tagging.Status, warns: Bool) {
    let style = DownloadRow.style(.staged, failedStage: nil, tagging: tagging, answering: true)
    #expect(style.warnsTagging == warns)
    #expect(!style.isDimmed && !style.isFailed)
}

@Test(arguments: [
    (JobState.staged, DownloadRow.Group.needsReview),
    (.approved, .needsReview),
    (.importing, .needsReview),
    (.candidateFound, .downloading),
    (.downloading, .downloading),
    (.downloaded, .downloading),
    (.queued, .waiting),
    (.searching, .waiting),
    (.notFound, .waiting),
    (.failed, .failed),
])
func eachLiveStateHasASection(state: JobState, group: DownloadRow.Group) {
    #expect(DownloadRow.group(state) == group)
}

@Test(arguments: [JobState.imported, .rejected, .cancelled])
func terminalJobsAreNotListed(state: JobState) {
    #expect(DownloadRow.group(state) == nil)
    #expect(DownloadRow(job(1, state), machine: "Studio") == nil)
}

@Test(arguments: [
    (JobState.staged, DownloadJob.Tagging.Status.clean, Optional("Studio"), true),
    (.staged, .clean, "Kitchen", false),
    (.staged, .clean, nil, false),
    (.staged, .discrepancy, "Studio", false),
    (.staged, .none, "Studio", false),
    (.staged, .running, "Studio", false),
    (.approved, .clean, "Studio", false),
    (.downloaded, .clean, "Studio", false),
])
func approveNeedsAStagedCleanJobThisMacHasClaimed(
    state: JobState, tagging: DownloadJob.Tagging.Status, claimer: String?, enabled: Bool
) {
    let review = claimer.map { DownloadJob.Hold(machine: $0, expiresAt: 1_794_150_000) }
    #expect(
        DownloadRow.canApprove(state, tagging: tagging, review: review, machine: "Studio")
            == enabled)
}

@Test func aJobClaimedOnAnotherMacSaysWhereAndCantBeApprovedHere() throws {
    let claimed = job(1) {
        $0.tagging = DownloadJob.Tagging(status: .clean, reasons: [])
        $0.review = DownloadJob.Hold(machine: "Kitchen", expiresAt: 1_794_150_000)
    }
    let row = try #require(DownloadRow(claimed, machine: "Studio"))
    #expect(row.claimedElsewhere == "Being reviewed on Kitchen")
    #expect(!row.canApprove)
    #expect(try #require(DownloadRow(claimed, machine: "Kitchen")).claimedElsewhere == nil)
}

@Test(arguments: [
    (JobState.downloading, DownloadJob.Tagging.Status.none, ""),
    (.staged, .none, "Pending"),
    (.staged, .running, "Tagging"),
    (.staged, .clean, "Clean"),
    (.staged, .discrepancy, "Discrepancy"),
    (.staged, .error, "Error"),
    (.approved, .clean, "Clean"),
    (.failed, .error, "Error"),
    (.failed, .none, ""),
])
func theTaggingColumnNamesTheStatusOnceThereAreFiles(
    state: JobState, status: DownloadJob.Tagging.Status, label: String
) {
    let tagging = DownloadRow.tagging(
        DownloadJob.Tagging(status: status, reasons: ["track 2 is 40 s off"]), state: state)
    #expect(tagging.label == label)
    #expect(tagging.status == status)
    #expect(tagging.reasons == ["track 2 is 40 s off"])
}

@Test func aRowSaysWhatItIsInWords() throws {
    let downloading = job(1, .downloading) {
        $0.progress = try? replyDecoder.decode(
            DownloadJob.Progress.self,
            from: Data(
                #"{"files_done": 3, "files_total": 12, "bytes_done": 25, "bytes_total": 100}"#
                    .utf8))
    }
    let row = try #require(DownloadRow(downloading, machine: "Studio"))
    #expect(row.album == "Made-Up Artist - Made-Up Album (1999)")
    #expect(row.state == "Downloading, 3 of 12 files")
    #expect(row.progress == 0.25)
    #expect(row.format == "FLAC 16/44.1, 2 files")
    let failed = job(2, .failed) {
        $0.failedStage = .move
        $0.reason = "the destination is taken"
        $0.candidate = nil
    }
    let failedRow = try #require(DownloadRow(failed, machine: "Studio"))
    #expect(failedRow.state == "Failed at move: the destination is taken")
    #expect(failedRow.format == "FLAC")
    #expect(failedRow.progress == nil)
}

@Test func rowsAreListedBySectionThenNewestFirst() {
    let jobs = [
        job(1, .queued, created: 100), job(2, .staged, created: 100),
        job(3, .failed, created: 300), job(4, .staged, created: 200),
        job(5, .downloading, created: 50), job(6, .imported, created: 900),
    ]
    let rows = jobs.compactMap { DownloadRow($0, machine: "Studio") }
        .sorted(by: DownloadRow.listed)
    #expect(rows.map(\.id) == [4, 2, 5, 1, 3])
}

@Test(arguments: [
    (JobState.queued, DownloadJob.Tagging.Status.none, true),
    (.searching, .none, true),
    (.candidateFound, .none, true),
    (.downloading, .none, true),
    (.downloaded, .none, true),
    (.staged, .none, true),
    (.staged, .running, true),
    (.staged, .clean, false),
    (.staged, .discrepancy, false),
    (.approved, .clean, true),
    (.importing, .clean, true),
    (.notFound, .none, false),
    (.failed, .none, false),
    (.imported, .clean, false),
    (.cancelled, .none, false),
])
func aJobIsMovingWhileTheServiceOrAPlayerWorksOnIt(
    state: JobState, tagging: DownloadJob.Tagging.Status, moving: Bool
) {
    let one = job(1, state) { $0.tagging = DownloadJob.Tagging(status: tagging, reasons: []) }
    #expect(DownloadsModel.isMoving(one) == moving)
    #expect(DownloadsModel.interval(windowOpen: true, jobs: [one]) == (moving ? 2 : 60))
    #expect(DownloadsModel.interval(windowOpen: false, jobs: [one]) == 60)
}

@MainActor
private func model(_ service: FakeService) -> DownloadsModel {
    let clock = service.clock
    return DownloadsModel(
        service: service.service, machine: "Studio",
        now: { Date(timeIntervalSince1970: clock.now) },
        sleep: { try await clock.sleep($0) })
}

@MainActor @Test func itPollsEveryMinuteUntilTheWindowOpensOnAMovingJob() async {
    let service = FakeService([job(1, .downloading)])
    let clock = service.clock
    let downloads = model(service)
    downloads.start()
    await eventually("the first poll and its wait") { clock.waiting == [60] }
    #expect(service.listed.count == 1)
    #expect(downloads.rows.map(\.id) == [1])

    downloads.setWindowOpen(true)
    await eventually("a poll on opening, then a 2 s wait") { clock.waiting == [2] }
    #expect(service.listed.count == 2)
    clock.advance(by: 2)
    await eventually("the next poll") { service.listed.count == 3 && clock.waiting == [2] }

    // Once nothing moves, the open window waits a minute too.
    service.put(job(1, .notFound))
    clock.advance(by: 2)
    await eventually("a poll that finds it waiting") {
        service.listed.count == 4 && clock.waiting == [60]
    }

    // Closing the window doesn't poll, and goes on waiting a minute.
    downloads.setWindowOpen(false)
    await eventually("a minute's wait after closing") { clock.waiting == [60] }
    #expect(service.listed.count == 4)
    downloads.stop()
    await eventually("no wait after stopping") { clock.waiting.isEmpty }
}

@MainActor @Test func eachPollAsksFromTheLastEpochAndRevision() async {
    let service = FakeService([job(1), job(2)])
    let downloads = model(service)
    var took: [[Int]] = []
    downloads.took = { took.append($0.map(\.id).sorted()) }
    await downloads.poll()
    service.put(job(2, .approved))
    await downloads.poll()
    #expect(service.listed.map(\.epoch) == [nil, "e1"])
    #expect(service.listed.map(\.after) == [0, 2])
    #expect(downloads.rows.first { $0.id == 2 }?.state == "Approved")
    #expect(took == [[1, 2], [1, 2]])
}

@MainActor @Test func aRebuiltServiceResetsTheRows() async {
    let service = FakeService([job(1), job(2)])
    let downloads = model(service)
    await downloads.poll()
    #expect(downloads.rows.map(\.id).sorted() == [1, 2])
    service.rebuild([job(3)])
    await downloads.poll()
    #expect(downloads.rows.map(\.id) == [3])
    #expect(downloads.jobs.epoch == "e1'")
    #expect(downloads.jobs.after == 1)
}

@MainActor @Test func aServiceThatDoesntAnswerKeepsTheRowsDimmedAndSaysWhere() async throws {
    let service = FakeService([
        job(1) {
            $0.tagging = DownloadJob.Tagging(status: .clean, reasons: [])
            $0.review = DownloadJob.Hold(machine: "Studio", expiresAt: 1_794_150_000)
        }
    ])
    let downloads = model(service)
    #expect(downloads.connection == .waiting)
    await downloads.poll()
    #expect(downloads.connection == .answering)
    #expect(downloads.rows.first?.canApprove == true)

    service.down = true
    var told: [String] = []
    downloads.took = { _ in told.append("took") }
    await downloads.poll()
    guard case .down(let message, let lastGood) = downloads.connection else {
        Issue.record("\(downloads.connection)")
        return
    }
    #expect(message.contains("192.0.2.7:8080"))
    #expect(lastGood == Date(timeIntervalSince1970: service.clock.now))
    let row = try #require(downloads.rows.first)
    #expect(row.id == 1)
    #expect(row.style.isDimmed)
    #expect(!row.canApprove)
    #expect(told.isEmpty)

    service.down = false
    await downloads.poll()
    #expect(downloads.connection == .answering)
    #expect(downloads.rows.first?.style.isDimmed == false)
}

/// Holds the first list until `open`, counting the lists running at once.
private final class HeldList: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private var calls = 0
    private var longest = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var opened = false

    var started: Int { lock.withLock { calls } }
    var most: Int { lock.withLock { longest } }
    var isHolding: Bool { lock.withLock { gate != nil } }

    func enter() async {
        let first = lock.withLock { () -> Bool in
            running += 1
            calls += 1
            longest = max(longest, running)
            return calls == 1
        }
        guard first else { return }
        await withCheckedContinuation { (wake: CheckedContinuation<Void, Never>) in
            let resume = lock.withLock { () -> Bool in
                if opened { return true }
                gate = wake
                return false
            }
            if resume { wake.resume() }
        }
    }

    func leave() { lock.withLock { running -= 1 } }

    func open() {
        lock.withLock { () -> CheckedContinuation<Void, Never>? in
            opened = true
            defer { gate = nil }
            return gate
        }?.resume()
    }
}

@MainActor @Test func pollsRunOneAtATimeSoAnOldReplyCantOverwriteANewerOne() async {
    let service = FakeService([job(1)])
    let held = HeldList()
    var wrapped = service.service
    let inner = wrapped.refreshed
    wrapped.refreshed = { jobs throws(RecommenderError) in
        await held.enter()
        defer { held.leave() }
        return try await inner(jobs)
    }
    let downloads = DownloadsModel(
        service: wrapped, machine: FakeService.machine, now: { Date(timeIntervalSince1970: 0) },
        sleep: { try await service.clock.sleep($0) })
    let first = Task { await downloads.poll() }
    await eventually("the first list held") { held.isHolding }
    let second = Task { await downloads.poll() }
    for _ in 0..<200 { await Task.yield() }
    #expect(held.started == 1, "the second waits for the first")
    held.open()
    await first.value
    await second.value
    #expect(held.started == 2)
    #expect(held.most == 1)
    #expect(downloads.rows.map(\.id) == [1])
}

@MainActor @Test func aPollThatBringsNothingNewChangesNothingShown() async {
    let service = FakeService([job(1)])
    let downloads = model(service)
    var changes = 0
    downloads.changed = { changes += 1 }
    await downloads.poll()
    #expect(changes == 1, "the first answer changes the connection")
    await downloads.poll()
    await downloads.poll()
    #expect(changes == 1)

    service.put(
        job(1, revision: 2) { $0.tagging = DownloadJob.Tagging(status: .clean, reasons: []) })
    await downloads.poll()
    #expect(changes == 2)
    service.down = true
    await downloads.poll()
    #expect(changes == 3)
    await downloads.poll()
    #expect(changes == 3, "the same failure again")
}
