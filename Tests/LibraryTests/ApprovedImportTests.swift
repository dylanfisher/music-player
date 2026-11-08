import Darwin
import Foundation
import Testing

@testable import Library
@testable import Metadata
@testable import Recommender

private let share = "smb://HAL9000/music"

/// `MoveFolders`'s share, its `library` folder found on `share`, and for an upgrade an MP3
/// album of release 77 in the library: "01 First.mp3", played, rated, loved and in "Mix", and
/// "02 Second.mp3", both on disk and in the index.
private final class ImportFolders {
    let folders: MoveFolders
    let playlist: Int64
    let played: Int64
    /// The directories each run asked to rescan.
    let rescanned = Rescans()

    init() throws {
        let folders = try MoveFolders()
        self.folders = folders
        let old = { (name: String) in folders.library + "/Artist/Album/" + name }
        let index = folders.index
        try index.relocate(share: share, path: "library", to: folders.library)
        try FileManager.default.createDirectory(
            atPath: folders.library + "/Artist/Album", withIntermediateDirectories: true)
        for name in Self.oldNames {
            #expect(
                FileManager.default.createFile(atPath: old(name), contents: Data("mp3".utf8)))
        }
        try index.store(
            Self.oldNames.map { name in
                Crafted(
                    path: old(name), title: name, album: "Album", codec: .mp3,
                    custom: [DiscogsKey.releaseID: "77"]
                ).scanned
            })
        played = try #require(try index.track(path: old(Self.oldNames[0]))).id
        try index.recordPlay(old(Self.oldNames[0]), at: 1_700_000_000)
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
        let old = Self.oldNames.enumerated().map { offset, name in
            UpgradeOldFile(
                sharePath: "library/Artist/Album/" + name, path: oldPath(name),
                position: String(offset + 1), hasStats: offset == 0)
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
        carry: (@Sendable ([(from: String, to: String)]) async throws -> MoveListImport)? = nil
    ) -> ImportRun {
        let watcher = LibraryWatcher(databaseURL: index.fileURL, networkReaders: nil)
        let rescanned = rescanned
        return ImportRun(
            index: index, move: folders.mover(calls), trash: trash,
            carry: carry ?? { try await watcher.importMoves(lines: $0) },
            rescan: { rescanned.add($0) })
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
    #expect(reason.contains("release 78, not 77"))
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
    ImportFolders.oldNames.map(setup.oldPath).allSatisfy {
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
