import AppKit
import Foundation
import Testing

@testable import Analysis
@testable import Downloads
@testable import Fixtures
@testable import Library
@testable import Recommender

// What blocks Approve, what it approves, and the sheet that shows it.

private func oldFile(_ name: String, _ position: String?, stats: Bool = false) -> UpgradeOldFile {
    UpgradeOldFile(
        sharePath: "library/\(name)", path: "/Volumes/music/library/\(name)", position: position,
        hasStats: stats)
}

private func plan(
    upgrade: Bool = false, resuming: Bool = false, movesProblem: String? = nil,
    origins: [StagedOrigin] = []
) -> ApprovalPlan {
    let old = [oldFile("01.mp3", "1"), oldFile("02.mp3", "2"), oldFile("03.mp3", nil, stats: true)]
    let staged = job(5, resuming ? .importing : .staged) {
        $0.tagging.status = .clean
        if upgrade {
            $0.source = .upgrade
            $0.upgrade = DownloadJob.Upgrade(
                currentQuality: "MP3 320 kbps", oldPaths: old.map(\.sharePath))
        }
    }
    return ApprovalPlan(
        job: staged, resuming: resuming,
        moves: staged.files.map { ($0.name, "/Volumes/music/library/A/\($0.name)") },
        movesProblem: movesProblem, old: upgrade ? old : [],
        unmatched: upgrade
            ? UpgradeMapping(old: old, new: staged.files.map { ($0.name, $0.position) }).unmatched
            : [],
        upgradeProblem: nil, origins: origins, originsProblem: nil)
}

private let lossy = StagedOrigin(
    path: "/s/job-5/01 First Song.flac",
    verdicts: [Verdict(kind: .lossyOrigin, text: "suspect lossy origin: cutoff at 16.0 kHz")],
    failure: nil)

@Test func aNewAlbumWithACleanCheckApprovesAsItIs() throws {
    let clean = StagedOrigin(path: "/s/job-5/01 First Song.flac", verdicts: [], failure: nil)
    let plan = plan(origins: [clean])
    #expect(plan.blockers(ticked: [], acknowledgedOrigins: false).isEmpty)
    let approved = try #require(plan.approved(ticked: [], acknowledgedOrigins: false))
    #expect(approved.jobID == 5)
    #expect(approved.folder == "job-5")
    #expect(approved.state == .staged)
    #expect(approved.upgrade == nil)
}

@Test func aLossyOriginBlocksUntilAcknowledged() {
    let plan = plan(origins: [lossy])
    #expect(plan.originsBlock)
    #expect(plan.blockers(ticked: [], acknowledgedOrigins: false).count == 1)
    #expect(plan.approved(ticked: [], acknowledgedOrigins: false) == nil)
    #expect(plan.approved(ticked: [], acknowledgedOrigins: true) != nil)
}

@Test func aFileTheMoveRefusesBlocksApproveButNotAResume() {
    #expect(plan(movesProblem: "already in the library: x").approved(ticked: [], acknowledgedOrigins: false) == nil)
    #expect(
        plan(resuming: true, movesProblem: "x").approved(ticked: [], acknowledgedOrigins: false)?
            .state == .importing)
}

@Test func anUpgradeWaitsForEachUnmatchedOldFileToBeTicked() throws {
    let plan = plan(upgrade: true)
    #expect(plan.unmatched.map(\.sharePath) == ["library/03.mp3"])
    #expect(plan.approved(ticked: [], acknowledgedOrigins: false) == nil)
    let approved = try #require(
        plan.approved(ticked: ["library/03.mp3", "library/01.mp3"], acknowledgedOrigins: false))
    #expect(approved.upgrade?.old.count == 3)
    #expect(approved.upgrade?.acknowledged == ["library/03.mp3"], "only the unmatched count")
}

@MainActor
@Test func theSheetSaysThePermanentDeleteAndEnablesApproveOnceTicked() throws {
    let sheet = ApproveSheet(plan: plan(upgrade: true, origins: [lossy]), album: "A - B")
    let page = try #require(sheet.window?.contentView as? NSStackView)
    let texts = page.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
    #expect(texts.contains(ApproveSheet.deleteWarning))
    #expect(ApproveSheet.deleteWarning.contains("deleted permanently"))
    #expect(!sheet.approveButton.isEnabled)
    #expect(sheet.unmatchedBoxes.count == 1)
    click(sheet.unmatchedBoxes[0])
    #expect(!sheet.approveButton.isEnabled, "the lossy origin still waits")
    click(sheet.acknowledgeBox)
    #expect(sheet.approveButton.isEnabled)
    #expect(sheet.blockersLabel.isHidden)
    #expect(ApproveSheet.originLines(sheet.plan) == ["01 First Song.flac: suspect lossy origin: cutoff at 16.0 kHz"])
}
