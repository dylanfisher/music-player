import Darwin
import Foundation
import Testing

@testable import Library
@testable import Metadata

/// A temporary share with a `staging` folder holding the job `job-7`'s two tagged FLACs and a
/// `library` folder beside it, and an index for the ledger.
final class MoveFolders {
    let share: String
    let index: LibraryIndex

    init() throws {
        share =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-move-\(UUID().uuidString)").path
        for folder in ["staging/job-7", "library"] {
            try FileManager.default.createDirectory(
                atPath: share + "/" + folder, withIntermediateDirectories: true)
        }
        index = try LibraryIndex(
            at: URL(fileURLWithPath: share + ".sqlite", isDirectory: false))
        try stage("01.flac", title: "First", track: 1)
        try stage("02.flac", title: "Second", track: 2)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: share)
        try? FileManager.default.removeItem(atPath: share + ".sqlite")
    }

    var staging: String { share + "/staging" }
    var library: String { share + "/library" }

    func stage(_ name: String, title: String, track: Int) throws {
        try taggedFLAC(tags: [
            "TITLE": title, "ARTIST": "Artist", "ALBUM": "Album", "TRACKNUMBER": "\(track)",
        ]).write(to: URL(fileURLWithPath: staging + "/job-7/" + name, isDirectory: false))
    }

    /// The staged files as the service listed them.
    func files() throws -> [(name: String, sizeBytes: Int)] {
        try ["01.flac", "02.flac"].map { name in
            let size =
                try FileManager.default.attributesOfItem(
                    atPath: staging + "/job-7/" + name)[.size] as! Int
            return (name, size)
        }
    }

    func mover(_ calls: MoveCalls = MoveCalls()) -> LibraryFolderMove {
        LibraryFolderMove(
            stagingRoot: staging, libraryFolder: library, shareRoot: share, calls: calls)
    }

    func moveIn(_ calls: MoveCalls = MoveCalls(), files: [(name: String, sizeBytes: Int)]? = nil)
        throws -> [String]
    {
        try mover(calls).moveIn(
            job: 7, release: 77, folder: "job-7", files: try files ?? self.files(), ledger: index)
    }

    var destinations: [String] {
        [library + "/Artist/Album/01 First.flac", library + "/Artist/Album/02 Second.flac"]
    }

    func staged() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: staging + "/job-7").sorted()
    }
}

private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

@Test func anApprovedAlbumIsRenamedIntoTheLibraryWithAStepEach() throws {
    let folders = try MoveFolders()
    let sizes = try folders.files()
    #expect(try folders.moveIn() == folders.destinations)
    #expect(try folders.staged().isEmpty)
    #expect(folders.destinations.allSatisfy(exists))
    #expect(
        try folders.index.importSteps(job: 7) == [
            ImportStep(
                jobID: 7, releaseID: 77, kind: .moved, path: "job-7/01.flac",
                destination: "library/Artist/Album/01 First.flac", sizeBytes: sizes[0].sizeBytes),
            ImportStep(
                jobID: 7, releaseID: 77, kind: .moved, path: "job-7/02.flac",
                destination: "library/Artist/Album/02 Second.flac",
                sizeBytes: sizes[1].sizeBytes),
        ])
}

@Test func aTakenDestinationRefusesTheWholeAlbum() throws {
    let folders = try MoveFolders()
    try FileManager.default.createDirectory(
        atPath: folders.library + "/Artist/Album", withIntermediateDirectories: true)
    let other = Data("someone else's".utf8)
    try other.write(to: URL(fileURLWithPath: folders.destinations[1], isDirectory: false))

    #expect(throws: MoveRefusal.collisions([folders.destinations[1]])) {
        try folders.moveIn()
    }
    #expect(try folders.staged() == ["01.flac", "02.flac"])
    #expect(!exists(folders.destinations[0]))
    #expect(try Data(contentsOf: URL(fileURLWithPath: folders.destinations[1])) == other)
    #expect(try folders.index.importSteps(job: 7).isEmpty)
}

@Test func aFileItReplacesIsSetAsideBeforeItsNewOneTakesThePath() throws {
    let folders = try MoveFolders()
    try FileManager.default.createDirectory(
        atPath: folders.library + "/Artist/Album", withIntermediateDirectories: true)
    let old = Data("the old copy".utf8)
    try old.write(to: URL(fileURLWithPath: folders.destinations[0], isDirectory: false))
    let aside = folders.library + "/Artist/Album/.upgrade-7-0"
    #expect(
        try folders.mover().destinations(
            folder: "job-7", files: try folders.files(), replacing: [folders.destinations[0]])
            == folders.destinations)

    #expect(
        try folders.mover().moveIn(
            job: 7, release: 77, folder: "job-7", files: try folders.files(),
            asides: [folders.destinations[0]: aside], ledger: folders.index)
            == folders.destinations)
    #expect(try Data(contentsOf: URL(fileURLWithPath: aside)) == old)
    #expect(try folders.staged().isEmpty)
    #expect(folders.destinations.allSatisfy(exists))
}

@Test func aMoveCutShortAfterItsSetAsideResumes() throws {
    let folders = try MoveFolders()
    try FileManager.default.createDirectory(
        atPath: folders.library + "/Artist/Album", withIntermediateDirectories: true)
    try Data("old".utf8).write(
        to: URL(fileURLWithPath: folders.destinations[0], isDirectory: false))
    let aside = folders.library + "/Artist/Album/.upgrade-7-0"
    var calls = MoveCalls()
    calls.renameExclusive = { from, to in
        from.hasSuffix("01.flac")
            ? EIO : (renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 ? 0 : errno)
    }
    let move = { (calls: MoveCalls) in
        try folders.mover(calls).moveIn(
            job: 7, release: 77, folder: "job-7", files: try folders.files(),
            asides: [folders.destinations[0]: aside], ledger: folders.index)
    }
    #expect(throws: MoveRefusal.self) { try move(calls) }
    #expect(exists(aside))
    #expect(!exists(folders.destinations[0]))

    #expect(try move(MoveCalls()) == folders.destinations)
    #expect(exists(aside))
    #expect(try folders.staged().isEmpty)
}

@Test func twoFilesWithOneDestinationRefuseTheAlbum() throws {
    let folders = try MoveFolders()
    try folders.stage("02.flac", title: "First", track: 1)
    #expect(throws: MoveRefusal.collisions([folders.destinations[0]])) {
        try folders.moveIn()
    }
    #expect(try folders.staged() == ["01.flac", "02.flac"])
}

@Test func foldersOnTwoVolumesAreRefused() throws {
    let folders = try MoveFolders()
    var calls = MoveCalls()
    let library = folders.library
    calls.volume = { path in path.hasSuffix("/library") ? 2 : 1 }
    #expect(throws: MoveRefusal.otherVolume(staging: folders.staging, library: library)) {
        try folders.moveIn(calls)
    }
    #expect(try folders.staged() == ["01.flac", "02.flac"])
}

@Test func aShareThatRefusesRenameExclGetsLstatAndRename() throws {
    let folders = try MoveFolders()
    var calls = MoveCalls()
    calls.renameExclusive = { _, _ in ENOTSUP }
    #expect(try folders.moveIn(calls) == folders.destinations)
    #expect(folders.destinations.allSatisfy(exists))
    #expect(try folders.staged().isEmpty)
}

@Test func theFallbacksLstatKeepsAFileThatArrivedAfterThePlan() throws {
    let folders = try MoveFolders()
    var calls = MoveCalls()
    let arrived = Data("arrived".utf8)
    calls.renameExclusive = { _, to in
        try? arrived.write(to: URL(fileURLWithPath: to, isDirectory: false))
        return EINVAL
    }
    #expect(throws: MoveRefusal.collisions([folders.destinations[0]])) {
        try folders.moveIn(calls)
    }
    #expect(try Data(contentsOf: URL(fileURLWithPath: folders.destinations[0])) == arrived)
    #expect(try folders.staged() == ["01.flac", "02.flac"])
}

@Test func aSourceLinkedFromOutsideStagingIsRefused() throws {
    let folders = try MoveFolders()
    let outside = folders.share + "/elsewhere.flac"
    try FileManager.default.moveItem(atPath: folders.staging + "/job-7/02.flac", toPath: outside)
    try FileManager.default.createSymbolicLink(
        atPath: folders.staging + "/job-7/02.flac", withDestinationPath: outside)
    var files = try folders.files()
    files[1].sizeBytes = try FileManager.default.attributesOfItem(atPath: outside)[.size] as! Int
    #expect(throws: MoveRefusal.outsideStaging(folders.staging + "/job-7/02.flac")) {
        try folders.moveIn(files: files)
    }
    #expect(exists(outside))
    #expect(!exists(folders.destinations[0]))
}

/// A name with `..` parts that reaches out of the staging folder is refused with nothing
/// moved, though a file is there to move (ADR 0025, row 67).
@Test func aStagedNameThatClimbsOutOfStagingIsRefused() throws {
    let folders = try MoveFolders()
    let outside = folders.share + "/elsewhere.flac"
    try FileManager.default.copyItem(atPath: folders.staging + "/job-7/02.flac", toPath: outside)
    var files = try folders.files()
    files[1].name = "../../elsewhere.flac"
    #expect(throws: MoveRefusal.outsideStaging(folders.staging + "/job-7/../../elsewhere.flac")) {
        try folders.moveIn(files: files)
    }
    #expect(exists(outside))
    #expect(try folders.staged() == ["01.flac", "02.flac"])
    #expect(!exists(folders.destinations[0]))
    #expect(try folders.index.importSteps(job: 7).isEmpty)
}

@Test func aDestinationLinkedOutTheLibraryIsRefused() throws {
    let folders = try MoveFolders()
    let outside = folders.share + "/elsewhere"
    try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        atPath: folders.library + "/Artist", withDestinationPath: outside)
    #expect(throws: MoveRefusal.outsideLibrary(folders.library + "/Artist/Album")) {
        try folders.moveIn()
    }
    #expect(try folders.staged() == ["01.flac", "02.flac"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside).isEmpty)
}

@Test func aStagingFolderInsideTheLibraryFolderIsRefused() throws {
    let folders = try MoveFolders()
    let move = LibraryFolderMove(
        stagingRoot: folders.staging, libraryFolder: folders.share, shareRoot: folders.share)
    #expect(throws: MoveRefusal.overlap(staging: folders.staging, library: folders.share)) {
        try move.moveIn(
            job: 7, release: 77, folder: "job-7", files: try folders.files(),
            ledger: folders.index)
    }
    #expect(try folders.staged() == ["01.flac", "02.flac"])
}

@Test func aFileNotTheStagedSizeIsRefused() throws {
    let folders = try MoveFolders()
    var files = try folders.files()
    files[0].sizeBytes += 1
    #expect {
        try folders.moveIn(files: files)
    } throws: { error in
        guard case .wrongSize = error as? MoveRefusal else { return false }
        return true
    }
    #expect(try folders.staged() == ["01.flac", "02.flac"])
}

@Test func aMoveThatFailedPartwayResumesFromTheLedger() throws {
    let folders = try MoveFolders()
    let files = try folders.files()
    var calls = MoveCalls()
    calls.renameExclusive = { from, to in
        from.hasSuffix("02.flac")
            ? EIO : (renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 ? 0 : errno)
    }
    #expect {
        try folders.moveIn(calls)
    } throws: { error in
        guard case .failed = error as? MoveRefusal else { return false }
        return true
    }
    #expect(exists(folders.destinations[0]))
    #expect(try folders.staged() == ["02.flac"])

    // The first file is no longer staged, so its destination comes from the ledger.
    #expect(try folders.moveIn(files: files) == folders.destinations)
    #expect(try folders.staged().isEmpty)
    #expect(try folders.index.importSteps(job: 7).count == 2)
    // And a run after that finds everything done.
    #expect(try folders.moveIn(files: files) == folders.destinations)
}

@Test func aResumeRefusesAMovedFileOfTheWrongSize() throws {
    let folders = try MoveFolders()
    let files = try folders.files()
    _ = try folders.moveIn()
    try Data("cut short".utf8).write(
        to: URL(fileURLWithPath: folders.destinations[1], isDirectory: false))
    #expect {
        try folders.moveIn(files: files)
    } throws: { error in
        guard
            case .wrongSize(folders.destinations[1], _, files[1].sizeBytes) = error as? MoveRefusal
        else { return false }
        return true
    }
}

@Test func aResumeRefusesAStagedFileSwappedForALinkOutside() throws {
    let folders = try MoveFolders()
    let files = try folders.files()
    var calls = MoveCalls()
    calls.renameExclusive = { from, to in
        from.hasSuffix("02.flac")
            ? EIO : (renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 ? 0 : errno)
    }
    #expect(throws: MoveRefusal.self) { try folders.moveIn(calls) }
    let staged = folders.staging + "/job-7/02.flac"
    let outside = folders.share + "/elsewhere.flac"
    try FileManager.default.moveItem(atPath: staged, toPath: outside)
    try FileManager.default.createSymbolicLink(atPath: staged, withDestinationPath: outside)
    #expect(throws: MoveRefusal.outsideStaging(staged)) { try folders.moveIn(files: files) }
    #expect(exists(outside))
    #expect(!exists(folders.destinations[1]))
}

@Test func aMacWithoutTheLedgerRefusesAnAlbumAnotherMovedInPart() throws {
    let folders = try MoveFolders()
    let files = try folders.files()
    try FileManager.default.removeItem(atPath: folders.staging + "/job-7/01.flac")
    #expect(throws: MoveRefusal.notStaged(folders.staging + "/job-7/01.flac")) {
        try folders.moveIn(files: files)
    }
    #expect(try folders.staged() == ["02.flac"])
}

/// The library album of release 77 at the album's destinations, with a third track the
/// download doesn't have, on disk and in the index.
private func libraryAlbum(
    _ folders: MoveFolders, paths given: [String]? = nil
) throws {
    try FileManager.default.createDirectory(
        atPath: folders.library + "/Artist/Album", withIntermediateDirectories: true)
    let paths = given ?? folders.destinations + [folders.library + "/Artist/Album/03 Third.flac"]
    for path in paths {
        #expect(FileManager.default.createFile(atPath: path, contents: Data("old".utf8)))
    }
    try folders.index.store(
        paths.enumerated().map { offset, path in
            Crafted(
                path: path, title: "Old \(offset)", album: "Album", number: offset + 1,
                custom: [DiscogsKey.releaseID: "77"]
            ).scanned
        })
}

@Test func anAlbumsFilesAreListedRelativeToTheShareInTrackOrder() throws {
    let folders = try MoveFolders()
    try libraryAlbum(folders)
    let album = try #require(try folders.index.track(path: folders.destinations[0])?.albumID)
    #expect(
        try folders.index.albumFiles(album, shareRoot: folders.mover().shareRoot) == [
            "library/Artist/Album/01 First.flac", "library/Artist/Album/02 Second.flac",
            "library/Artist/Album/03 Third.flac",
        ])
    // An album with a file off the share has none to replace.
    #expect(try folders.index.albumFiles(album, shareRoot: "/Volumes/elsewhere") == nil)
}

/// Whether the temporary folder's volume ignores case, as a Mac's startup disk and the NAS do.
let tempIgnoresCase = pathconf(NSTemporaryDirectory(), _PC_CASE_SENSITIVE) == 0

@Test(.enabled(if: tempIgnoresCase))
func anAlbumSpelledInAnotherCaseIsReplacedAtThePathsItHas() throws {
    let folders = try MoveFolders()
    let lower = ["artist/Album/01 first.flac", "artist/Album/02 second.flac"]
    try FileManager.default.createDirectory(
        atPath: folders.library + "/artist/Album", withIntermediateDirectories: true)
    try libraryAlbum(folders, paths: lower.map { folders.library + "/" + $0 })
    let id = try #require(
        try folders.index.track(path: folders.library + "/" + lower[0])?.albumID)
    let album = try folders.index.albumFiles(id, shareRoot: folders.mover().shareRoot)
    #expect(album == lower.map { "library/" + $0 })
    #expect(
        try folders.mover().destinations(
            folder: "job-7", files: try folders.files(),
            replacing: folders.mover().libraryPaths(album ?? []))
            == lower.map { folders.library + "/" + $0 })
}
