import Foundation
import Testing

@testable import Analysis
@testable import Downloads
@testable import Library
@testable import Recommender

// Approve Safe Matches Automatically (ADR 0193): a staged job tagged clean whose plan asks
// nothing goes through Approve's import unasked; any other stays staged, its claim given back.

private struct NoFolder: Error {}

private let clean = DownloadJob.Tagging(status: .clean, reasons: [])

/// Counts the calls made of it.
private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

/// Approve's plan for `job` as the sheet would show it once checked, with the check's findings
/// `origins`.
private func plan(_ job: DownloadJob, origins: [StagedOrigin] = []) -> ApprovalPlan {
    ApprovalPlan(
        job: job, resuming: false, moves: job.files.map { ($0.name, "/l/A/\($0.name)") },
        movesProblem: nil, old: [], unmatched: [], upgradeProblem: nil, origins: origins,
        originsProblem: nil)
}

@Test func onlyAStagedCleanJobNoOtherMacReviewsIsLookedAt() {
    let me = FakeService.machine
    #expect(Downloads.mayApproveUnasked(job(1) { $0.tagging = clean }, machine: me))
    #expect(
        Downloads.mayApproveUnasked(
            job(1) {
                $0.tagging = clean
                $0.review = DownloadJob.Hold(machine: me, expiresAt: 0)
            }, machine: me))
    #expect(
        !Downloads.mayApproveUnasked(
            job(1) {
                $0.tagging = clean
                $0.review = DownloadJob.Hold(machine: "Kitchen", expiresAt: 0)
            }, machine: me))
    #expect(!Downloads.mayApproveUnasked(job(1), machine: me), "not tagged yet")
    #expect(
        !Downloads.mayApproveUnasked(
            job(1) { $0.tagging = DownloadJob.Tagging(status: .discrepancy, reasons: ["x"]) },
            machine: me))
    #expect(!Downloads.mayApproveUnasked(job(1, .imported) { $0.tagging = clean }, machine: me))
}

/// Turning the box on looks at the jobs staged already, and a safe one's import is Approve's:
/// the coordinator claims it again and runs `ImportRun`, which here finds no folders.
@MainActor
@Test func turningItOnRunsApprovesImportForAStagedSafeJob() async throws {
    let fake = FakeService([job(1) { $0.tagging = clean }])
    let calls = Calls()
    let nowhere = FileManager.default.temporaryDirectory.path + "/\(UUID().uuidString)"
    let (downloads, session) = try await started(fake.service) {
        guard calls.next() == 1 else { throw NoFolder() }
        return ImportPlaces(stagingRoot: nowhere, libraryFolder: nowhere, shareRoot: nowhere)
    }
    downloads.checkedPlan = { job, _, _ in plan(job) }
    await eventually("the first poll") { session.model.job(1) != nil }
    downloads.approveSafe()
    #expect(downloads.approving == nil, "off, nothing is approved")
    #expect(!fake.eventTypes.contains("claim"))

    downloads.autoApprove = true
    #expect(downloads.approving?.job == 1)
    #expect(!downloads.applies(.reject, try #require(session.model.rows.first)))
    await eventually("the import refused") { session.model.leftForReview[1] != nil }
    #expect(
        session.model.leftForReview[1]?.hasPrefix("the staging or library folder wasn't found")
            == true)
    #expect(fake.eventTypes.filter { $0 == "claim" }.count == 2, "the review's, then the import's")
    await eventually("the claim given back") { fake.job(1)?.review == nil }
    #expect(fake.job(1)?.state == .staged)
    downloads.stop()
}

/// A plan that asks the owner anything leaves the job staged, saying why in its row, and it
/// isn't looked at again until the box is turned on again.
@MainActor
@Test func aJobWhosePlanAsksSomethingStaysStaged() async throws {
    let fake = FakeService([job(1) { $0.tagging = clean }])
    let nowhere = FileManager.default.temporaryDirectory.path + "/\(UUID().uuidString)"
    let (downloads, session) = try await started(fake.service) {
        ImportPlaces(stagingRoot: nowhere, libraryFolder: nowhere, shareRoot: nowhere)
    }
    let lossy = StagedOrigin(
        path: "\(nowhere)/job-1/01 First Song.flac",
        verdicts: [Verdict(kind: .lossyOrigin, text: "suspect lossy origin")], failure: nil)
    downloads.checkedPlan = { job, _, _ in plan(job, origins: [lossy]) }
    await eventually("the first poll") { session.model.job(1) != nil }
    downloads.autoApprove = true
    await eventually("left for review") { session.model.leftForReview[1] != nil }
    #expect(session.model.leftForReview[1] == "Acknowledge what the lossy-origin check found.")
    await eventually("the claim given back") { fake.job(1)?.review == nil }
    #expect(fake.eventTypes == ["claim", "release"])
    await eventually("the row says why") {
        session.model.rows.first?.stateDetail
            == "Not approved automatically: Acknowledge what the lossy-origin check found."
    }
    await eventually("done") { downloads.approving == nil }
    downloads.approveSafe()
    #expect(downloads.approving == nil, "not looked at again")

    downloads.autoApprove = false
    downloads.autoApprove = true
    #expect(session.model.leftForReview.isEmpty)
    await eventually("looked at again") {
        fake.eventTypes.filter { $0 == "claim" }.count == 2
    }
    await eventually("done") { downloads.approving == nil }
    downloads.stop()
}

/// Files the owner tagged as another release in the tagger are left for Approve, unclaimed.
@MainActor
@Test func aJobTaggedAsAnotherReleaseIsLeftUnclaimed() async throws {
    let fake = FakeService([job(1) { $0.tagging = clean }])
    let (downloads, session) = try await started(fake.service) { throw NoFolder() }
    await eventually("the first poll") { session.model.job(1) != nil }
    session.model.setTagged([1: TaggedRelease(folder: "job-1", releaseID: 5151)])
    await downloads.approveUnasked(try #require(fake.job(1)), session)
    #expect(session.model.leftForReview[1] == Downloads.taggedAsAnotherRelease)
    #expect(fake.eventTypes.isEmpty)
    downloads.stop()
}
