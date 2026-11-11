import Darwin
import Foundation
import Testing

@testable import Library
@testable import Metadata
@testable import Recommender
@testable import TagWriter

private let share = "smb://HAL9000/music"

/// `MoveFolders`'s share, its `library` folder found on `share`, and for an upgrade an album of
/// release 77 in the library: "01 First.mp3", played, rated, loved and in "Mix", and
/// "02 Second.mp3", both on disk and in the index; or, with `names`, files of those names, and
/// with `release`, tagged with that release, nil for none.
private final class ImportFolders {
    let folders: MoveFolders
    let names: [String]
    let release: String?
    let playlist: Int64
    let played: Int64
    /// The directories each run asked to rescan.
    let rescanned = Rescans()

    init(names: [String] = ImportFolders.oldNames, release: String? = "77") throws {
        let folders = try MoveFolders()
        self.folders = folders
        self.names = names
        self.release = release
        let old = { (name: String) in folders.library + "/Artist/Album/" + name }
        let index = folders.index
        try index.relocate(share: share, path: "library", to: folders.library)
        try FileManager.default.createDirectory(
            atPath: folders.library + "/Artist/Album", withIntermediateDirectories: true)
        for name in names {
            #expect(
                FileManager.default.createFile(atPath: old(name), contents: Data("mp3".utf8)))
        }
        try index.store(
            names.map { name in
                Crafted(
                    path: old(name), title: name, album: "Album", codec: .mp3,
                    custom: release.map { [DiscogsKey.releaseID: $0] } ?? [:]
                ).scanned
            })
        played = try #require(try index.track(path: old(names[0]))).id
        try index.recordPlay(old(names[0]), at: 1_700_000_000)
        try index.setRating(4, trackIDs: [played])
        try index.toggle(.liked, trackIDs: [played])
        playlist = try index.createPlaylist(named: "Mix")
        _ = try index.addToPlaylist(playlist, trackIDs: [played])
    }

    static let oldNames = ["01 First.mp3", "02 Second.mp3"]

    var index: LibraryIndex { folders.index }

    func oldPath(_ name: String) -> String { folders.library + "/Artist/Album/" + name }

    func job(state: JobState = .staged, upgrade: Bool, positions: [String?] = ["1", "2"])
        throws -> ApprovedImport
    {
        let files = try folders.files().enumerated().map { offset, file in
            DownloadJob.File(
                name: file.name, sizeBytes: file.sizeBytes, position: positions[offset])
        }
        let old = names.enumerated().map { offset, name in
            UpgradeOldFile(
                sharePath: "library/Artist/Album/" + name, path: oldPath(name),
                position: String(offset + 1), hasStats: offset == 0, release: release)
        }
        return ApprovedImport(
            jobID: 7, releaseID: 77, state: state, folder: "job-7", files: files,
            upgrade: upgrade ? ApprovedImport.Upgrade(old: old, acknowledged: []) : nil)
    }

    /// A run whose trash deletes the files, as a share with no Trash does, and whose stats go
    /// through the watcher.
    func run(
        calls: MoveCalls = MoveCalls(),
        trash: @escaping @Sendable ([URL]) async -> String? = deleting,
        carry: (@Sendable ([(from: String, to: String)]) async throws -> MoveListImport)? = nil,
        deliver: @escaping @Sendable () async -> String? = { nil }
    ) -> ImportRun {
        let watcher = LibraryWatcher(databaseURL: index.fileURL, networkReaders: nil)
        let rescanned = rescanned
        return ImportRun(
            index: index, move: folders.mover(calls), trash: trash,
            carry: carry ?? { try await watcher.importMoves(lines: $0) },
            rescan: { rescanned.add($0) }, deliver: deliver)
    }

    /// The outbox's reports for the job, by type.
    func reports() throws -> [String] {
        try index.importReports().map { report in
            #expect(report.jobID == 7 && report.releaseID == 77)
            let object = try JSONSerialization.jsonObject(with: Data(report.body.utf8))
            return (object as? [String: Any])?["type"] as? String ?? report.body
        }
    }

    /// Expects the upgrade done: the new files in, the old ones gone, and once a scan reads
    /// the new files, the first holding the old first track's stats, logged for the other Macs.
    func expectUpgraded() throws {
        #expect(try folders.staged().isEmpty)
        #expect(folders.destinations.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        #expect(!Self.oldNames.map(oldPath).contains { FileManager.default.fileExists(atPath: $0) })
        try index.store(
            folders.destinations.map { Crafted(path: $0, title: "new", album: "Album").scanned })
        let track = try #require(try index.track(path: folders.destinations[0]))
        #expect(track.id == played)
        #expect(track.playCount == 1)
        #expect(track.rating == 4)
        #expect(track.loved)
        #expect(try index.playlistTrackIDs(playlist) == [played])
        let moves = try index.database.prepare("SELECT line FROM \(syncOutboxTable)").map {
            try SyncRecord(line: Array(try $0.text(0).utf8)[...]).event
        }.filter { if case .move = $0 { true } else { false } }
        #expect(
            moves == [
                .move(
                    from: "music/library/Artist/Album/01 First.mp3",
                    to: "music/library/Artist/Album/01 First.flac"),
                .move(
                    from: "music/library/Artist/Album/02 Second.mp3",
                    to: "music/library/Artist/Album/02 Second.flac"),
            ])
    }
}

final class Rescans: @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [[String]] = []

    func add(_ directories: [String]) { lock.withLock { runs.append(directories) } }
    var all: [[String]] { lock.withLock { runs } }
}

@Sendable private func deleting(_ urls: [URL]) async -> String? {
    for url in urls { try? FileManager.default.removeItem(at: url) }
    return nil
}

private let newAlbumReports = ["approved", "importing", "imported"]

@Test func aNewAlbumIsMovedInRescannedAndReportedInOrder() async throws {
    let setup = try ImportFolders()
    let outcome = await setup.run().run(try setup.job(upgrade: false))
    #expect(outcome == .imported(setup.folders.destinations))
    #expect(try setup.folders.staged().isEmpty)
    #expect(try setup.reports() == newAlbumReports)
    #expect(setup.rescanned.all == [[setup.folders.library + "/Artist/Album"]])
    // A new album deletes nothing.
    #expect(oldFilesThere(setup))
}

@Test func anApprovedJobReportsOnlyImportingAndImported() async throws {
    let setup = try ImportFolders()
    _ = await setup.run().run(try setup.job(state: .approved, upgrade: false))
    #expect(try setup.reports() == ["importing", "imported"])
}

@Test func aJobNotStagedOrApprovingIsRefusedUntouched() async throws {
    let setup = try ImportFolders()
    let outcome = await setup.run().run(try setup.job(state: .rejected, upgrade: false))
    #expect(outcome == .refused("the job is rejected, not staged or approving"))
    #expect(try setup.reports().isEmpty)
    #expect(try setup.folders.staged() == ["01.flac", "02.flac"])
}

@Test func anUpgradeReplacesTheOldFilesAndCarriesTheirStats() async throws {
    let setup = try ImportFolders()
    let outcome = await setup.run().run(try setup.job(upgrade: true))
    #expect(outcome == .imported(setup.folders.destinations))
    try setup.expectUpgraded()
    #expect(try setup.reports() == newAlbumReports)
}

/// On a share with no Trash the import deletes the old files itself, one by one, asking
/// nothing, as the app wires it (ADR 0199).
@Test func anUpgradeOnAShareWithNoTrashDeletesTheOldFiles() async throws {
    let setup = try ImportFolders()
    let offered = OfferedToTrash()
    let noTrash = setup.run(trash: { urls in
        await trashOrDelete(urls) { url in
            offered.add(url.lastPathComponent)
            throw CocoaError(.featureUnsupported)
        }
    })
    let outcome = await noTrash.run(try setup.job(upgrade: true))
    #expect(outcome == .imported(setup.folders.destinations))
    try setup.expectUpgraded()
    #expect(offered.all.sorted() == ImportFolders.oldNames, "each offered to the Trash first")
}

/// The names of the files given to a stand-in Trash.
private final class OfferedToTrash: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []

    func add(_ name: String) { lock.withLock { names.append(name) } }
    var all: [String] { lock.withLock { names } }
}

/// On a volume with a Trash the old files go to it.
@Test func anUpgradeOnAVolumeWithATrashMovesTheOldFilesThere() async throws {
    let setup = try ImportFolders()
    let trashFolder = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: trashFolder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: trashFolder) }
    let toTrash = setup.run(trash: { urls in
        await trashOrDelete(urls) { url in
            try FileManager.default.moveItem(
                at: url, to: trashFolder.appendingPathComponent(url.lastPathComponent))
        }
    })
    let outcome = await toTrash.run(try setup.job(upgrade: true))
    #expect(outcome == .imported(setup.folders.destinations))
    try setup.expectUpgraded()
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: trashFolder.path).sorted()
            == ImportFolders.oldNames)
}

/// An album found by its artist and title carries another release id, or none: its files
/// are held to the one each carried when the owner approved (ADR 0169).
@Test(arguments: ["12", nil])
func anUpgradeOfAnAlbumOfAnotherReleaseReplacesIt(_ release: String?) async throws {
    let setup = try ImportFolders(release: release)
    let outcome = await setup.run().run(try setup.job(upgrade: true))
    #expect(outcome == .imported(setup.folders.destinations))
    try setup.expectUpgraded()
}

/// One re-tagged with another release since the owner approved isn't the album's any more, so
/// the Trash never gets it, on this run or the one after.
@Test func anOldFileRetaggedSinceTheApprovalIsntDeleted() async throws {
    let setup = try ImportFolders(release: "12")
    let job = try setup.job(upgrade: true)
    try setup.index.store(
        setup.names.map { name in
            Crafted(
                path: setup.oldPath(name), title: name, album: "Album", codec: .mp3,
                custom: [DiscogsKey.releaseID: "13"]
            ).scanned
        })
    let outcome = await setup.run().run(job)
    guard case .failed(.delete, let why) = outcome else {
        Issue.record("not failed at the delete: \(outcome)")
        return
    }
    #expect(why.contains("is tagged with release 13, not release 12"))
    #expect(oldFilesThere(setup))
    // A run after it reads the release each is held to from the ledger.
    var resumed = job
    resumed.upgrade = nil
    resumed.state = .importing
    guard case .failed(.delete, _) = await setup.run().run(resumed) else {
        Issue.record("the resume deleted them")
        return
    }
    #expect(oldFilesThere(setup))
}

@Test func anUntickedOldFileWithNoCounterpartBlocksTheUpgrade() async throws {
    let setup = try ImportFolders()
    var job = try setup.job(upgrade: true, positions: ["1", nil])
    let outcome = await setup.run().run(job)
    #expect(
        outcome
            == .refused(
                "these old files have no new one, and aren't ticked to lose:"
                    + " library/Artist/Album/02 Second.mp3"))
    #expect(try setup.folders.staged() == ["01.flac", "02.flac"])
    #expect(try setup.reports().isEmpty)

    job.upgrade?.acknowledged = ["library/Artist/Album/02 Second.mp3"]
    #expect(await setup.run().run(job) == .imported(setup.folders.destinations))
    #expect(!FileManager.default.fileExists(atPath: setup.oldPath("02 Second.mp3")))
}

@Test func aTruncatedMovedFileStopsTheUpgradeBeforeTheDelete() async throws {
    let setup = try ImportFolders()
    var calls = MoveCalls()
    calls.renameExclusive = { from, to in
        guard renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 else { return errno }
        if to.hasSuffix("02 Second.flac") { truncate(to, 10) }
        return 0
    }
    let outcome = await setup.run(calls: calls).run(try setup.job(upgrade: true))
    guard case .failed(.move, let reason) = outcome else {
        Issue.record("\(outcome)")
        return
    }
    #expect(reason.contains("02 Second.flac is 10 bytes"))
    #expect(oldFilesThere(setup))
    #expect(try setup.reports() == ["approved", "importing", "failed"])
}

@Test func aMoveThatFailedResumesWithoutReportingTwice() async throws {
    let setup = try ImportFolders()
    var calls = MoveCalls()
    calls.renameExclusive = { from, to in
        from.hasSuffix("02.flac")
            ? EIO : (renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 ? 0 : errno)
    }
    let job = try setup.job(upgrade: true)
    guard case .failed(.move, _) = await setup.run(calls: calls).run(job) else {
        Issue.record("the move didn't fail")
        return
    }
    #expect(oldFilesThere(setup))
    #expect(await setup.run().run(job) == .imported(setup.folders.destinations))
    try setup.expectUpgraded()
    #expect(try setup.reports() == newAlbumReports)
}

@Test func aDeleteTheTrashRefusedResumesFromTheDelete() async throws {
    let setup = try ImportFolders()
    let job = try setup.job(upgrade: true)
    let outcome = await setup.run(trash: { _ in "no Trash on this share" }).run(job)
    guard case .failed(.delete, let reason) = outcome else {
        Issue.record("\(outcome)")
        return
    }
    #expect(reason.hasSuffix(": no Trash on this share"))
    #expect(setup.folders.destinations.allSatisfy { FileManager.default.fileExists(atPath: $0) })
    #expect(oldFilesThere(setup))

    #expect(await setup.run().run(job) == .imported(setup.folders.destinations))
    try setup.expectUpgraded()
    #expect(try setup.reports() == newAlbumReports)
}

@Test func aDeleteRefusesAnOldFileNoLongerOfTheRelease() async throws {
    let setup = try ImportFolders()
    try setup.index.store([
        Crafted(
            path: setup.oldPath("02 Second.mp3"), title: "retagged", album: "Album", codec: .mp3,
            custom: [DiscogsKey.releaseID: "78"]
        ).scanned
    ])
    let outcome = await setup.run().run(try setup.job(upgrade: true))
    guard case .failed(.delete, let reason) = outcome else {
        Issue.record("\(outcome)")
        return
    }
    #expect(reason.contains("release 78, not release 77"))
    #expect(oldFilesThere(setup))
}

@Test func aCarryThatFailedResumesFromTheCarry() async throws {
    let setup = try ImportFolders()
    let job = try setup.job(upgrade: true)
    struct Down: Error {}
    let outcome = await setup.run(carry: { _ in throw Down() }).run(job)
    guard case .failed(.carry, _) = outcome else {
        Issue.record("\(outcome)")
        return
    }
    // The old files are gone: the resume finds nothing to delete and carries the stats.
    #expect(
        !ImportFolders.oldNames.map(setup.oldPath).contains {
            FileManager.default.fileExists(atPath: $0)
        })
    #expect(await setup.run().run(job) == .imported(setup.folders.destinations))
    try setup.expectUpgraded()
    #expect(try setup.reports() == newAlbumReports)
}

@Test func aRunAfterImportedChangesNothing() async throws {
    let setup = try ImportFolders()
    let job = try setup.job(upgrade: true)
    #expect(await setup.run().run(job) == .imported(setup.folders.destinations))
    let reports = try setup.index.importReports()
    let steps = try setup.index.importSteps(job: 7)
    var refusing = MoveCalls()
    refusing.renameExclusive = { _, _ in EIO }
    let again = await setup.run(calls: refusing, trash: { _ in "called" }).run(job)
    #expect(again == .imported(setup.folders.destinations))
    #expect(try setup.index.importReports() == reports)
    #expect(try setup.index.importSteps(job: 7) == steps)
}

@Test func aRunCutShortAfterItsReportsDoesntQueueThemAgain() async throws {
    let setup = try ImportFolders()
    // A run queued its reports and stopped before the move; the service never had them.
    _ = try setup.index.queueImportReport(job: 7, release: 77, body: HandoffEvent.approved.json)
    _ = try setup.index.queueImportReport(job: 7, release: 77, body: HandoffEvent.importing.json)
    #expect(
        await setup.run().run(try setup.job(upgrade: false))
            == .imported(setup.folders.destinations))
    #expect(try setup.reports() == newAlbumReports)
}

/// Whether both old files are still on disk.
private func oldFilesThere(_ setup: ImportFolders) -> Bool {
    setup.names.map(setup.oldPath).allSatisfy {
        FileManager.default.fileExists(atPath: $0)
    }
}

@Test func aCarryWithAProblemLineFailsAtTheCarry() async throws {
    let setup = try ImportFolders()
    let outcome = await setup.run(carry: { _ in
        MoveListImport(problems: [MoveListProblem(line: 2, reason: "the new file isn't there")])
    }).run(try setup.job(upgrade: true))
    #expect(outcome == .failed(.carry, "line 2: the new file isn't there"))
    #expect(try setup.reports() == ["approved", "importing", "failed"])
}

/// Writes a long comment into each staged file, as a tag write does when the padding runs out,
/// and records what the files measure now, as the coordinator does after its write. Returns the
/// sizes before and after.
private func growStagedFiles(_ setup: ImportFolders) throws -> (before: [Int], after: [Int]) {
    let before = try setup.folders.files().map(\.sizeBytes)
    var edit = TagEdit()
    edit.values[.comment] = String(repeating: "x", count: 100_000)
    let writer = TagWriter(
        journal: TagUndoJournal(
            dataDirectory: URL(fileURLWithPath: setup.folders.share + "-journal", isDirectory: true)
        ))
    let report = writer.write(
        try setup.folders.files().map { (setup.folders.staging + "/job-7/" + $0.name, edit) })
    #expect(report.failures.isEmpty)
    let files = try setup.folders.files()
    try setup.index.recordStagedSizes(
        job: 7, release: 77, folder: "job-7",
        sizes: Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.sizeBytes) }))
    return (before, files.map(\.sizeBytes))
}

@Test func aNewAlbumWhoseTagWriteGrewItsFilesIsApprovedAgainstTheServicesSizes() async throws {
    let setup = try ImportFolders()
    // The service listed the files before the player wrote their tags.
    let job = try setup.job(upgrade: false)
    let sizes = try growStagedFiles(setup)
    #expect(zip(sizes.before, sizes.after).allSatisfy { $1 > $0 })
    #expect(await setup.run().run(job) == .imported(setup.folders.destinations))
    #expect(try setup.reports() == newAlbumReports)
}

@Test func anUpgradeWhoseTagWriteGrewItsFilesIsApprovedAgainstTheServicesSizes() async throws {
    let setup = try ImportFolders()
    let job = try setup.job(upgrade: true)
    _ = try growStagedFiles(setup)
    #expect(await setup.run().run(job) == .imported(setup.folders.destinations))
    try setup.expectUpgraded()
    #expect(try setup.reports() == newAlbumReports)
}

@Test func aFileThatChangedAfterTheTagWriteIsStillRefused() async throws {
    let setup = try ImportFolders()
    let job = try setup.job(upgrade: false)
    _ = try growStagedFiles(setup)
    let path = setup.folders.staging + "/job-7/02.flac"
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path, isDirectory: false))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("more".utf8))
    try handle.close()
    guard case .failed(.move, let reason) = await setup.run().run(job) else {
        Issue.record("the move didn't fail")
        return
    }
    #expect(reason.contains("02.flac"))
    #expect(try setup.folders.staged() == ["01.flac", "02.flac"])
}

@Test func stagedSizesAreKeptByNameAndForgottenWithTheJob() throws {
    let index = try LibraryIndex(
        at: FileManager.default.temporaryDirectory.appendingPathComponent(
            "sizes-\(UUID().uuidString).sqlite", isDirectory: false))
    try index.recordStagedSizes(job: 7, release: 77, folder: "job-7", sizes: ["a.flac": 5])
    try index.recordStagedSizes(job: 7, release: 77, folder: "job-7", sizes: ["a.flac": 9])
    try index.recordStagedSizes(job: 8, release: 78, folder: "job-8", sizes: ["a.flac": 1])
    #expect(try index.stagedSizes(job: 7, folder: "job-7") == ["a.flac": 9])
    #expect(try index.stagedSizes(job: 8, folder: "job-8") == ["a.flac": 1])
    try index.forgetImportJob(7)
    #expect(try index.stagedSizes(job: 7, folder: "job-7") == [:])
}

@Test func aServiceThatRefusesTheReportsMovesNothing() async throws {
    let setup = try ImportFolders()
    let heard = Heard()
    let url = setup.index.fileURL
    let outcome = await setup.run(deliver: {
        heard.record(try? LibraryIndex(at: url).importReports().map(\.body))
        return "the service refused approved"
    }).run(try setup.job(upgrade: true))
    #expect(outcome == .refused("the service refused approved"))
    // Both reports were queued for it to send, and the files hadn't moved when it did.
    #expect(heard.seen == [[HandoffEvent.approved.json, HandoffEvent.importing.json]])
    #expect(try setup.folders.staged() == ["01.flac", "02.flac"])
    #expect(try setup.index.importSteps(job: 7).isEmpty)
    #expect(oldFilesThere(setup))
}

final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [[String]] = []

    func record(_ reports: [String]?) { lock.withLock { all.append(reports ?? []) } }
    var seen: [[String]] { lock.withLock { all } }
}

/// The files the album's new files have names of: "01 First.flac" and "02 Second.flac".
private let samePathNames = ["01 First.flac", "02 Second.flac"]

/// The old files' hidden names while their new files take their paths.
private func asides(_ setup: ImportFolders) -> [String] {
    [0, 1].map { setup.folders.library + "/Artist/Album/.upgrade-7-\($0)" }
}

@Test func anUpgradeAtTheOldFilesPathsReplacesThemAndKeepsTheirStats() async throws {
    let setup = try ImportFolders(names: samePathNames)
    let oldBytes = try Data(contentsOf: URL(fileURLWithPath: setup.folders.destinations[0]))
    let carried = Rescans()
    let outcome = await setup.run(carry: { lines in
        carried.add(lines.map(\.from))
        return MoveListImport(problems: [])
    }).run(try setup.job(upgrade: true))
    #expect(outcome == .imported(setup.folders.destinations))
    #expect(try setup.folders.staged().isEmpty)
    #expect(asides(setup).allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    #expect(try Data(contentsOf: URL(fileURLWithPath: setup.folders.destinations[0])) != oldBytes)
    // The stats stay with the path, so nothing is carried.
    #expect(carried.all.isEmpty)
    try setup.index.store(
        setup.folders.destinations.map { Crafted(path: $0, title: "new", album: "Album").scanned })
    let track = try #require(try setup.index.track(path: setup.folders.destinations[0]))
    #expect(track.id == setup.played)
    #expect(track.playCount == 1)
    #expect(track.rating == 4)
    #expect(try setup.index.playlistTrackIDs(setup.playlist) == [setup.played])
    #expect(try setup.reports() == newAlbumReports)
}

@Test func aTruncatedFileAtAnOldPathKeepsTheOldFileAside() async throws {
    let setup = try ImportFolders(names: samePathNames)
    var calls = MoveCalls()
    calls.renameExclusive = { from, to in
        guard renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 else { return errno }
        if from.hasSuffix("02.flac") { truncate(to, 10) }
        return 0
    }
    let outcome = await setup.run(calls: calls).run(try setup.job(upgrade: true))
    guard case .failed(.move, let reason) = outcome else {
        Issue.record("\(outcome)")
        return
    }
    #expect(reason.contains("02 Second.flac is 10 bytes"))
    #expect(reason.contains(".upgrade-7-1"))
    #expect(asides(setup).allSatisfy { FileManager.default.fileExists(atPath: $0) })
}

@Test func aResumeWithoutTheSheetsUpgradeStillDeletesTheSetAsideFiles() async throws {
    let setup = try ImportFolders(names: samePathNames)
    let job = try setup.job(upgrade: true)
    guard case .failed(.delete, _) = await setup.run(trash: { _ in "refused" }).run(job) else {
        Issue.record("the delete didn't fail")
        return
    }
    #expect(asides(setup).allSatisfy { FileManager.default.fileExists(atPath: $0) })
    // A sheet built for the resume doesn't know the job replaces an album; the ledger does.
    var resumed = job
    resumed.state = .importing
    resumed.upgrade = nil
    #expect(await setup.run().run(resumed) == .imported(setup.folders.destinations))
    #expect(asides(setup).allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    #expect(setup.folders.destinations.allSatisfy { FileManager.default.fileExists(atPath: $0) })
}

@Test func aNewFileAtAnOldPathOfAnotherTrackRefusesTheUpgrade() async throws {
    let setup = try ImportFolders(names: samePathNames)
    // The old "01 First.flac" is placed second on the release, so the new first file would
    // take its path with the wrong track's stats.
    var job = try setup.job(upgrade: true)
    job.upgrade?.old[0].position = "2"
    job.upgrade?.old[1].position = "1"
    let outcome = await setup.run().run(job)
    guard case .failed(.move, let reason) = outcome else {
        Issue.record("\(outcome)")
        return
    }
    #expect(reason.hasPrefix("already in the library"))
    #expect(oldFilesThere(setup))
    #expect(try setup.folders.staged() == ["01.flac", "02.flac"])
}

@Test(.enabled(if: tempIgnoresCase))
func anUpgradeOfAnAlbumSpelledInAnotherCaseKeepsItsPathsAndStats() async throws {
    let setup = try ImportFolders(names: ["01 first.flac", "02 second.flac"])
    let old = setup.names.map(setup.oldPath)
    let outcome = await setup.run(carry: { _ in
        Issue.record("nothing to carry")
        return MoveListImport(problems: [])
    }).run(try setup.job(upgrade: true))
    #expect(outcome == .imported(old))
    #expect(try setup.folders.staged().isEmpty)
    #expect(asides(setup).allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: setup.folders.library + "/Artist/Album")
            .sorted() == setup.names)
    try setup.index.store(old.map { Crafted(path: $0, title: "new", album: "Album").scanned })
    let track = try #require(try setup.index.track(path: old[0]))
    #expect(track.id == setup.played)
    #expect(track.playCount == 1)
}
