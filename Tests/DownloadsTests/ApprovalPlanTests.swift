import AppKit
import Foundation
import Testing

@testable import Analysis
@testable import Discogs
@testable import Downloads
@testable import Fixtures
@testable import Library
@testable import Metadata
@testable import Recommender

// What blocks Approve, what it approves, and the sheet that shows it.

private func oldFile(_ name: String, _ position: String?, stats: Bool = false) -> UpgradeOldFile {
    UpgradeOldFile(
        sharePath: "library/\(name)", path: "/Volumes/music/library/\(name)", position: position,
        hasStats: stats, release: "4242")
}

private func plan(
    upgrade: Bool = false, resuming: Bool = false, movesProblem: String? = nil,
    origins: [StagedOrigin] = [], replacesAlbum: Bool = false, checking: Bool = false,
    replacedQuality: AudioQuality? = nil, byName: Bool = false
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
        upgradeProblem: nil, origins: origins, originsProblem: nil,
        replaced: replacesAlbum
            ? ApprovalPlan.Replaced(
                artist: "A", title: "B", byName: byName, files: old.count,
                quality: replacedQuality) : nil,
        keepBoth: replacesAlbum
            ? ApprovalPlan.KeepBoth(
                moves: staged.files.map { ($0.name, "/Volumes/music/library/A (2)/\($0.name)") },
                problem: nil) : nil,
        checking: checking)
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

/// The import Approve Safe Matches Automatically makes, or why it leaves the job (ADR 0193).
private func unasked(_ plan: ApprovalPlan) -> (ApprovedImport?, String?) {
    switch plan.unasked {
    case .approved(let approved): (approved, nil)
    case .left(let why): (nil, why)
    }
}

@Test func aPlanThatAsksNothingIsApprovedUnasked() throws {
    let clean = StagedOrigin(path: "/s/job-5/01 First Song.flac", verdicts: [], failure: nil)
    let (new, _) = unasked(plan(origins: [clean]))
    #expect(try #require(new).upgrade == nil)
    // An upgrade whose every old file has a new one replaces them all.
    var upgrade = plan(upgrade: true, origins: [clean])
    upgrade.unmatched = []
    let (approved, why) = unasked(upgrade)
    #expect(why == nil)
    #expect(approved?.upgrade?.old.count == 3)
    #expect(approved?.upgrade?.acknowledged == [])
}

@Test func aPlanThatAsksTheOwnerAnythingIsLeftForReview() {
    var notReplaced = plan()
    notReplaced.notReplaced = "2 albums in the library are tagged with this release"
    let left: [(ApprovalPlan, String)] = [
        (plan(origins: [lossy]), "Acknowledge what the lossy-origin check found."),
        (plan(upgrade: true), "Tick the 1 old file with no new one, to lose it."),
        (plan(movesProblem: "already in the library: x"), "already in the library: x"),
        (plan(upgrade: true, replacesAlbum: true), "it replaces a library album"),
        (notReplaced, "2 albums in the library"),
        (plan(checking: true), ApproveSheet.checkingNote),
        (plan(resuming: true), "the import has started already"),
    ]
    for (plan, words) in left {
        let (approved, why) = unasked(plan)
        #expect(approved == nil)
        #expect(why?.hasPrefix(words) == true, "\(why ?? "approved")")
    }
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
    let note = ApproveSheet.replacesNote(try #require(plan.replaced), staged: plan.stagedQuality)
    #expect(note.hasPrefix("Replaces 3 files in the library"))
    #expect(texts.contains(note))
    #expect(!note.contains("FLAC 16/44.1"), "the library album's quality isn't known")
    let known = ApproveSheet.replacesNote(
        ApprovalPlan.Replaced(artist: "A", title: "B", byName: false, files: 3, quality: mp3320),
        staged: plan.stagedQuality)
    #expect(known.contains(" Replaces MP3 320 kbps with FLAC 16/44.1. "))
    #expect(texts.contains(ApproveSheet.deleteWarning))
}

private let mp3320 = AudioQuality.lossy(format: "MP3", kbps: 320)

/// A job queued as a new album that replaces a library album of its release, found by its
/// release id, is approved unasked as the sheet's Approve would with Keep Both off, when the
/// download is clearly higher quality (ADR 0195).
@Test func aClearlyBetterNewAlbumReplacesTheLibrarysUnasked() throws {
    let clean = StagedOrigin(path: "/s/job-5/01 First Song.flac", verdicts: [], failure: nil)
    var plan = plan(
        upgrade: true, origins: [clean], replacesAlbum: true, replacedQuality: mp3320)
    #expect(plan.stagedQuality?.description == "FLAC 16/44.1")
    // Approve asks about an old file with no new one first.
    #expect(unasked(plan).1 == "Tick the 1 old file with no new one, to lose it.")
    plan.unmatched = []
    let (approved, why) = unasked(plan)
    #expect(why == nil)
    let sheets = try #require(plan.approved(ticked: [], acknowledgedOrigins: false))
    #expect(approved?.upgrade?.old == sheets.upgrade?.old)
    #expect(approved?.upgrade?.old.count == 3)
    #expect(approved?.upgrade?.acknowledged == [])
    #expect(approved?.folder == sheets.folder)
}

@Test func aNewAlbumThatIsntClearlyBetterThanTheOneItReplacesIsLeftSayingBoth() {
    let clean = StagedOrigin(path: "/s/job-5/01 First Song.flac", verdicts: [], failure: nil)
    let left = { (plan: ApprovalPlan) -> String? in
        var plan = plan
        plan.unmatched = []
        return unasked(plan).1
    }
    let cd = AudioQuality.lossless(format: "FLAC", bitDepth: 16, sampleRateHz: 44_100)
    #expect(
        left(plan(upgrade: true, origins: [clean], replacesAlbum: true, replacedQuality: cd))
            == "it isn't higher quality than the library's FLAC 16/44.1 (FLAC 16/44.1 isn't better)"
    )
    // The check read 16/44.1, whatever the peer said.
    var claimed = plan(upgrade: true, origins: [clean], replacesAlbum: true, replacedQuality: cd)
    claimed.job.candidate?.bitDepth = 24
    claimed.job.candidate?.sampleRateHz = 96_000
    #expect(left(claimed) == nil, "24/96 by the peer's word")
    var read = clean
    read.measures = FileMeasures(
        formatID: "flac", sampleRateHz: 44_100, storedBits: 16, channels: 2, isFloat: false,
        durationSeconds: 200, cutoffHz: nil, cutoffSteepnessDBPerKHz: nil, effectiveBits: 16,
        identicalChannels: false, peakDBFS: -1, truePeakDBTP: -1, clippedRuns: 0,
        dynamicRange: 10)
    claimed.origins = [read]
    #expect(left(claimed)?.hasPrefix("it isn't higher quality") == true)
    // Lossy over lossless.
    var lossy = plan(upgrade: true, origins: [clean], replacesAlbum: true, replacedQuality: cd)
    lossy.job.candidate?.format = .mp3
    lossy.job.candidate?.bitrateKbps = 320
    #expect(
        left(lossy)
            == "it isn't higher quality than the library's FLAC 16/44.1 (MP3 320 kbps isn't better)"
    )
    #expect(
        left(plan(upgrade: true, origins: [clean], replacesAlbum: true))
            == "it replaces a library album of unknown quality with FLAC 16/44.1, which can't be"
            + " compared")
    // Found by artist and title only, it's left however much better.
    #expect(
        left(
            plan(
                upgrade: true, origins: [clean], replacesAlbum: true, replacedQuality: mp3320,
                byName: true))?.contains("artist and title") == true)
}

/// Keep Both imports the job as a new album beside the one it would replace: no old files,
/// nothing to tick, and the moves beside the library's copy.
@MainActor
@Test func keepBothImportsItAsANewAlbum() throws {
    let plan = plan(upgrade: true, replacesAlbum: true)
    #expect(plan.approved(ticked: [], acknowledgedOrigins: false) == nil, "a file to tick")
    let kept = try #require(
        plan.approved(ticked: [], acknowledgedOrigins: false, keepingBoth: true))
    #expect(kept.upgrade == nil)
    let sheet = ApproveSheet(plan: plan, album: "A - B")
    #expect(sheet.oldTable.numberOfRows == 3)
    #expect(!sheet.approveButton.isEnabled)
    click(sheet.keepBothBox)
    #expect(sheet.approveButton.isEnabled)
    #expect(sheet.oldTable.numberOfRows == 0)
    #expect(sheet.files.map(\.destination).allSatisfy { $0.contains("A (2)") })
    // Unticked, the old files are back.
    click(sheet.keepBothBox)
    #expect(sheet.oldTable.numberOfRows == 3)

    // Where the new album's paths are taken, Keep Both can't go ahead.
    var taken = plan
    taken.keepBoth?.problem = "already in the library: A/01 First Song.flac"
    #expect(
        taken.blockers(ticked: ["library/03.mp3"], acknowledgedOrigins: false, keepingBoth: true)
            == ["already in the library: A/01 First Song.flac"])
}

/// While the check reads the files, their rows spin and Approve waits; once it's done, the
/// rows say what it found.
@MainActor
@Test func approveWaitsForTheCheckWithASpinnerInEachCheckedRow() throws {
    let waiting = plan(checking: true)
    #expect(
        waiting.blockers(ticked: [], acknowledgedOrigins: true) == [ApproveSheet.checkingNote])
    #expect(ApproveSheet.fileRows(waiting).map(\.checking) == [true, true])
    let sheet = ApproveSheet(job: waiting.job, album: "A - B", resuming: false)
    sheet.preparing(ApproveSheet.claimingStep)
    #expect(sheet.blockersLabel.stringValue == ApproveSheet.claimingStep)
    #expect(!sheet.approveButton.isEnabled)
    #expect(sheet.files.isEmpty)
    sheet.show(waiting)
    #expect(sheet.filesTable.numberOfRows == 2)
    #expect(!sheet.approveButton.isEnabled)
    let check = try #require(sheet.filesTable.tableColumns.last)
    #expect(sheet.tableView(sheet.filesTable, viewFor: check, row: 0) is NSStackView)
    sheet.show(plan(origins: [lossy]))
    #expect(sheet.files.map(\.checking) == [false, false])
    #expect(!sheet.approveButton.isEnabled, "the finding waits to be acknowledged")
    click(sheet.acknowledgeBox)
    #expect(sheet.approveButton.isEnabled)
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
        ApproveSheet.subtitle(plan.job)
            == "Discogs release 4242 · FLAC 16/44.1, 2 files · Replaces MP3 320 kbps")
    #expect(
        ApproveSheet.subtitle(plan.job, taggedAs: 5151)
            == "Tagged as Discogs release 5151, queued as 4242 · FLAC 16/44.1, 2 files"
            + " · Replaces MP3 320 kbps")
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

/// A library album of two tracks under `folder` in the share's library folder, in the index
/// only, tagged as `tags` says, for a job queued as a new album to find.
private func libraryAlbum(
    _ places: ImportPlaces, _ index: LibraryIndex, folder: String,
    _ tags: (inout TrackTags) -> Void
) throws {
    let paths = ["01.mp3", "02.mp3"].map { places.libraryFolder + "/" + folder + "/" + $0 }
    try index.store(
        paths.enumerated().map { offset, path in
            var tagged = TrackTags()
            tagged.title = "Old \(offset)"
            tagged.trackNumber = offset + 1
            tags(&tagged)
            let audio = TrackAudio(
                codec: .mp3, sampleRateHz: 44100, bitsPerSample: 16, channels: 2,
                lengthFrames: 44100 * 200)
            // 320 kbps for its 200 seconds.
            return ScannedFile(
                path: path, sizeBytes: 8_000_000, modifiedSeconds: 1, known: nil,
                outcome: .success(
                    ParsedFile(
                        metadata: TrackMetadata(tags: tagged, audio: audio, art: nil),
                        warnings: [], bytesRead: 0, readCount: 0)))
        })
}

/// Job 5 as the service staged it in `stagedShare`'s folder, at the sizes its files have.
private func stagedJob(_ sizes: [Int]) -> DownloadJob {
    var staged = job(5)
    staged.stagedPath = "job-5"
    staged.files = zip(staged.files, sizes).map {
        DownloadJob.File(name: $0.name, sizeBytes: $1, position: $0.position)
    }
    return staged
}

/// A job queued by hand whose release the library has is planned as an upgrade of that album,
/// found by its tracks' release id, else by its artist and title, with Keep Both's moves beside
/// it (ADR 0169).
@Test(arguments: [false, true])
func aJobQueuedByHandReplacesTheLibrarysAlbumOfItsRelease(_ byName: Bool) async throws {
    let (places, index, sizes) = try stagedShare()
    try libraryAlbum(places, index, folder: "Old") { tags in
        tags.album = byName ? "Made-Up Album" : "Something Else"
        tags.albumArtist = "Made-Up Artist"
        if !byName { tags.custom = [DiscogsKey.releaseID: "4242"] }
    }
    let plan = await ApprovalPlan.build(
        stagedJob(sizes), places: places, databaseURL: index.fileURL, catalog: nil)
    #expect(
        plan.replaced
            == ApprovalPlan.Replaced(
                artist: "Made-Up Artist", title: byName ? "Made-Up Album" : "Something Else",
                byName: byName, files: 2, quality: .lossy(format: "MP3", kbps: 320)))
    #expect(plan.isUpgrade)
    #expect(plan.checking)
    #expect(plan.movesProblem == nil)
    #expect(plan.keepBoth?.problem == nil)
    #expect(plan.keepBoth?.moves.count == 2)
    // Without a catalog, the old files can't be placed on the release; Keep Both can go on.
    #expect(plan.upgradeProblem?.contains("not in the local catalog") == true)
    #expect(
        plan.blockers(ticked: [], acknowledgedOrigins: true, keepingBoth: true)
            == [ApproveSheet.checkingNote])
}

@Test func twoLibraryAlbumsOfTheReleaseLeaveTheJobANewAlbum() async throws {
    let (places, index, sizes) = try stagedShare()
    for folder in ["One", "Two"] {
        try libraryAlbum(places, index, folder: folder) { tags in
            tags.album = folder
            tags.custom = [DiscogsKey.releaseID: "4242"]
        }
    }
    let plan = await ApprovalPlan.build(
        stagedJob(sizes), places: places, databaseURL: index.fileURL, catalog: nil)
    #expect(plan.replaced == nil)
    #expect(!plan.isUpgrade)
    #expect(
        plan.notReplaced?.hasPrefix("2 albums in the library are tagged with this release") == true)
    #expect(plan.moves.count == 2)
}

/// The check runs after the plan, so the sheet can show the plan first.
@Test func theCheckRunsAfterThePlan() async throws {
    let (places, index, sizes) = try stagedShare()
    let plan = await ApprovalPlan.build(
        stagedJob(sizes), places: places, databaseURL: index.fileURL, catalog: nil)
    #expect(plan.checking && plan.origins.isEmpty && plan.originsProblem == nil)
    let checked = try await plan.checked(places: places)
    #expect(!checked.checking)
    #expect(
        checked.origins.map(\.path)
            == stagedOriginChoice(
                plan.job.files.map {
                    places.stagingRoot + "/job-5/" + $0.name
                }))
}
