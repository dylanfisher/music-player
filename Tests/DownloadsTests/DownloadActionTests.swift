import Foundation
import Testing

@testable import Downloads
@testable import Recommender

// Which of the window's actions apply to a job, as tables, and the policies a job may ask for.

private let me = FakeService.machine

private func held(_ machine: String) -> DownloadJob.Hold {
    DownloadJob.Hold(machine: machine, expiresAt: 1_794_200_000)
}

@Test(arguments: [
    (DownloadAction.approve, JobState.staged, DownloadJob.Tagging.Status.clean, true),
    (.approve, .staged, .discrepancy, false),
    (.approve, .staged, .none, false),
    (.approve, .downloaded, .clean, false),
    (.reject, .staged, .discrepancy, true),
    (.reject, .approved, .clean, false),
    (.openInTagger, .staged, .discrepancy, true),
    (.openInTagger, .staged, .error, true),
    (.openInTagger, .staged, .clean, false),
    (.resumeHere, .importing, .clean, true),
    (.resumeHere, .approved, .clean, true),
    (.resumeHere, .staged, .clean, false),
    (.retry, .notFound, .none, true),
    (.retry, .failed, .none, true),
    (.retry, .staged, .none, false),
    (.cancel, .downloading, .none, true),
    (.cancel, .staged, .clean, true),
    (.cancel, .importing, .clean, false),
])
func eachActionAppliesToItsStates(
    action: DownloadAction, state: JobState, tagging: DownloadJob.Tagging.Status, applies: Bool
) {
    let job = job(1, state) { $0.tagging.status = tagging }
    #expect(
        DownloadAction.applies(action, to: job, machine: me, answering: true, canTag: true)
            == applies)
    // Nothing applies while the service doesn't answer.
    #expect(!DownloadAction.applies(action, to: job, machine: me, answering: false, canTag: true))
}

@Test(arguments: [
    (DownloadAction.approve, false),
    (.reject, false),
    (.openInTagger, false),
    (.cancel, false),
    (.resumeHere, true),
])
func aJobAnotherMacReviewsTakesOnlyResumeHere(action: DownloadAction, applies: Bool) {
    let state: JobState = action == .resumeHere ? .importing : .staged
    let job = job(1, state) {
        $0.tagging.status = action == .openInTagger ? .discrepancy : .clean
        $0.review = held("Living Room")
    }
    #expect(
        DownloadAction.applies(action, to: job, machine: me, answering: true, canTag: true)
            == applies)
    var mine = job
    mine.review = held(me)
    #expect(DownloadAction.applies(action, to: mine, machine: me, answering: true, canTag: true))
}

@Test func withoutACatalogTheTaggerDoesntOpen() {
    let job = job(1) { $0.tagging.status = .discrepancy }
    #expect(
        !DownloadAction.applies(.openInTagger, to: job, machine: me, answering: true, canTag: false))
    #expect(DownloadAction.applies(.reject, to: job, machine: me, answering: true, canTag: false))
}

@Test(arguments: [
    (DownloadJob.FailedStage.search, true, true),
    (.download, true, true),
    (.stage, false, true),
    (.tag, false, true),
    (.move, false, false),
    (.delete, false, false),
    (.carry, false, false),
])
func aFailedJobCancelsUpToTaggingAndSearchesAgainOnlyFromItsDownload(
    stage: DownloadJob.FailedStage, searches: Bool, cancels: Bool
) {
    let job = job(1, .failed) { $0.failedStage = stage }
    #expect(DownloadAction.retrySearches(job) == searches)
    #expect(
        DownloadAction.applies(.cancel, to: job, machine: me, answering: true, canTag: true)
            == cancels)
}

@Test func anUpgradeIsOfferedOnlyLosslessPolicies() {
    #expect(FormatPolicy.offered(upgrade: true) == [.flac, .lossless])
    #expect(FormatPolicy.offered(upgrade: false) == [.flac, .lossless, .mp3320, .any])
}
