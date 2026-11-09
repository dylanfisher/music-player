import AppKit
import Foundation
import Testing

@testable import Analysis
@testable import Discogs
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
    origins: [StagedOrigin] = [], replacesAlbum: Bool = false
) -> ApprovalPlan {
    let old = [oldFile("01.mp3", "1"), oldFile("02.mp3", "2"), oldFile("03.mp3", nil, stats: true)]
    let staged = job(5, resuming ? .importing : .staged) {
        $0.tagging.status = .clean
        if upgrade && !replacesAlbum {
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
        upgradeProblem: nil, origins: origins, originsProblem: nil, replacesAlbum: replacesAlbum)
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
    #expect(
        plan(movesProblem: "already in the library: x").approved(
            ticked: [], acknowledgedOrigins: false) == nil)
    #expect(
        plan(resuming: true, movesProblem: "x").approved(ticked: [], acknowledgedOrigins: false)?
            .state == .importing)
}

@Test func aStagedFolderOutsideTheStagingFolderIsNeverApproved() async throws {
    for resuming in [false, true] {
        var outside = job(5, resuming ? .importing : .staged) { $0.tagging.status = .clean }
        outside.stagedPath = "../library"
        let built = await ApprovalPlan.build(
            outside,
            places: ImportPlaces(stagingRoot: "/s", libraryFolder: "/l", shareRoot: "/"),
            databaseURL: URL(fileURLWithPath: "/nowhere.sqlite", isDirectory: false),
            catalog: nil)
        #expect(built.movesProblem?.contains("isn't one folder name") == true)
        #expect(!built.blockers(ticked: [], acknowledgedOrigins: true).isEmpty)
        #expect(built.approved(ticked: [], acknowledgedOrigins: true) == nil)
    }
    var tagged = job(5)
    tagged.stagedPath = "/"
    #expect(StagedJob(tagged) == nil, "nor tagged")
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
@Test func aNewAlbumThatReplacesOneInTheLibraryIsApprovedAsAnUpgrade() throws {
    let plan = plan(upgrade: true, replacesAlbum: true)
    #expect(plan.job.upgrade == nil)
    #expect(plan.isUpgrade)
    let approved = try #require(
        plan.approved(ticked: ["library/03.mp3"], acknowledgedOrigins: false))
    #expect(approved.upgrade?.old.count == 3)
    let sheet = ApproveSheet(plan: plan, album: "A - B")
    let page = try #require(sheet.window?.contentView as? NSStackView)
    let texts = page.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
    #expect(texts.contains(ApproveSheet.replacesAlbumNote))
    #expect(texts.contains(ApproveSheet.deleteWarning))
}

@MainActor
@Test func theSheetSaysThePermanentDeleteAndEnablesApproveOnceTicked() throws {
    let sheet = ApproveSheet(plan: plan(upgrade: true, origins: [lossy]), album: "A - B")
    let page = try #require(sheet.window?.contentView as? NSStackView)
    let texts = page.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
    #expect(texts.contains(ApproveSheet.deleteWarning))
    #expect(ApproveSheet.deleteWarning.contains("deleted permanently"))
    #expect(!sheet.approveButton.isEnabled)
    #expect(!sheet.blockersLabel.isHidden)
    // A box only for the old file with no new one.
    let tick = try #require(sheet.oldTable.tableColumns.first)
    #expect(sheet.tableView(sheet.oldTable, viewFor: tick, row: 0) == nil)
    let box = try #require(sheet.tableView(sheet.oldTable, viewFor: tick, row: 2) as? NSButton)
    click(box)
    #expect(sheet.ticked == ["library/03.mp3"])
    #expect(!sheet.approveButton.isEnabled, "the lossy origin still waits")
    click(sheet.acknowledgeBox)
    #expect(sheet.approveButton.isEnabled)
    #expect(sheet.blockersLabel.isHidden)
}

@MainActor
@Test func theFilesTableSaysWhereEachGoesAndWhatTheCheckFound() throws {
    var plan = plan(upgrade: true, origins: [lossy])
    plan.libraryFolder = "/Volumes/music/library"
    #expect(
        ApproveSheet.fileRows(plan) == [
            .init(
                name: "01 First Song.flac", destination: "A/01 First Song.flac",
                check: "suspect lossy origin: cutoff at 16.0 kHz", warns: true),
            .init(
                name: "02 Second Song.flac", destination: "A/02 Second Song.flac",
                check: "Not checked", warns: false),
        ])
    #expect(ApproveSheet.oldRows(plan).map(\.tickable) == [false, false, true])
    #expect(ApproveSheet.oldRows(plan).map(\.position) == ["1", "2", ""])
    #expect(ApproveSheet.oldRows(plan)[2].note.contains("plays"), "it has stats")
    #expect(
        ApproveSheet.subtitle(plan)
            == "Discogs release 4242 · FLAC 16/44.1, 2 files · Replaces MP3 320 kbps")
    let sheet = ApproveSheet(plan: plan, album: "A - B")
    #expect(
        sheet.filesTable.tableColumns.map(\.title) == [
            "File Name", "Moves To", "Lossy-Origin Check",
        ])
    #expect(sheet.filesTable.numberOfRows == 2 && sheet.oldTable.numberOfRows == 3)
}

@MainActor
@Test func aResumeListsTheFilesAlone() throws {
    let sheet = ApproveSheet(plan: plan(resuming: true), album: "A - B")
    #expect(sheet.filesTable.tableColumns.map(\.title) == ["File Name"])
    #expect(sheet.approveButton.title == DownloadAction.resumeHere.title)
    #expect(sheet.approveButton.isEnabled)
}

/// A temporary share with a staging folder of two tagged FLACs of the job 5, a library folder
/// beside it, and an index.
private func stagedShare() throws -> (places: ImportPlaces, index: LibraryIndex, sizes: [Int]) {
    let share = FileManager.default.temporaryDirectory.appendingPathComponent(
        "plan-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: share.appendingPathComponent("staging/job-5"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: share.appendingPathComponent("library"), withIntermediateDirectories: true)
    var info = Data()
    info.appendBigEndian(UInt16(4096))
    info.appendBigEndian(UInt16(4096))
    info.append(Data(count: 6))
    info.appendBigEndian(UInt64(44_100) << 44 | UInt64(1) << 41 | UInt64(15) << 36 | 4410)
    info.append(Data(count: 16))
    var sizes: [Int] = []
    for (offset, name) in ["01 First Song.flac", "02 Second Song.flac"].enumerated() {
        let tags = FixtureTags(
            title: "Song \(offset)", artist: "Artist", album: "Album", albumArtist: nil,
            genre: nil, date: nil, trackNumber: offset + 1, trackTotal: nil, discNumber: nil,
            discTotal: nil, compilation: false, comment: nil)
        let file = flacFile(
            streamInfo: info, frames: Data([0xFF, 0xF8, 0, 0]), tags: tags, art: nil,
            style: VorbisStyle(
                lowercaseKeys: false, combinedTrackNumber: false, paddingBytes: 100))
        try file.write(to: share.appendingPathComponent("staging/job-5/" + name))
        sizes.append(file.count)
    }
    let index = try LibraryIndex(at: share.appendingPathExtension("sqlite"))
    let places = ImportPlaces(
        stagingRoot: share.path + "/staging", libraryFolder: share.path + "/library",
        shareRoot: share.path)
    return (places, index, sizes)
}

@Test func theMovesAreCheckedAgainstTheSizesRecordedAfterTheTagWrite() async throws {
    let (places, index, sizes) = try stagedShare()
    // The service listed the files at other sizes than they have: the player's write changed them.
    var staged = job(5)
    staged.stagedPath = "job-5"
    staged.files = zip(staged.files, [sizes[0] - 30, sizes[1] - 30]).map { file, size in
        DownloadJob.File(name: file.name, sizeBytes: size, position: file.position)
    }
    let before = await ApprovalPlan.build(
        staged, places: places, databaseURL: index.fileURL, catalog: nil)
    #expect(before.movesProblem?.contains("bytes") == true)

    try index.recordStagedSizes(
        job: 5, release: 4242, folder: "job-5",
        sizes: ["01 First Song.flac": sizes[0], "02 Second Song.flac": sizes[1]])
    let after = await ApprovalPlan.build(
        staged, places: places, databaseURL: index.fileURL, catalog: nil)
    #expect(after.movesProblem == nil)
    #expect(after.moves.count == 2)
}
