import Darwin
import Foundation
import Testing

@testable import Library
@testable import Metadata

/// A temporary folder holding a `library` folder, and a file outside it, for Keep Files
/// Organized to rename in.
private final class OrganizeFolders {
    let root: String

    init() throws {
        root =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("organize-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(
            atPath: root + "/library", withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    var library: String { root + "/library" }

    /// A FLAC at `path`, relative to the root, tagged with `title`, track 1 of the album.
    @discardableResult
    func file(
        _ path: String, title: String, artist: String = "Artist", album: String = "Album",
        track: Int = 1
    ) throws -> String {
        let full = root + "/" + path
        try FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try taggedFLAC(tags: [
            "TITLE": title, "ARTIST": artist, "ALBUM": album, "TRACKNUMBER": "\(track)",
        ]).write(to: URL(fileURLWithPath: full, isDirectory: false))
        return full
    }

    func organize(_ paths: [String], _ calls: MoveCalls = MoveCalls()) -> FilesOrganized {
        moveToLayout(
            layoutMoves(paths, libraryFolder: library), libraryFolder: library, calls: calls)
    }
}

private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

@Test func aFileIsRenamedToItsLayoutInAnotherFolderAndItsEmptyFoldersGo() throws {
    let folders = try OrganizeFolders()
    let old = try folders.file("library/Old Artist/Old Album/song.flac", title: "Song")
    let result = folders.organize([old])
    let new = folders.library + "/Artist/Album/01 Song.flac"
    #expect(result.moved == [TrackMove(from: old, to: new)])
    #expect(exists(new))
    #expect(!exists(old))
    #expect(!exists(folders.library + "/Old Artist"))
    #expect(exists(folders.library))
    #expect(result.problemLines.isEmpty)
}

@Test func aFileAlreadyAtItsPathIsLeft() throws {
    let folders = try OrganizeFolders()
    let path = try folders.file("library/Artist/Album/01 Song.flac", title: "Song")
    let result = folders.organize([path])
    #expect(result.moved.isEmpty)
    #expect(result.inPlace == 1)
    #expect(exists(path))
}

@Test func aTakenNameSkipsTheFileAndListsIt() throws {
    let folders = try OrganizeFolders()
    let there = try folders.file("library/Artist/Album/01 Song.flac", title: "Other")
    let before = try Data(contentsOf: URL(fileURLWithPath: there, isDirectory: false))
    let old = try folders.file("library/Loose/song.flac", title: "Song")
    let planned = layoutMoves([old], libraryFolder: folders.library)
    let result = folders.organize([old])
    #expect(result.moved.isEmpty)
    #expect(result.problems == ["\(old): not moved, already in the library: \(there)"])
    #expect(planned.problems == result.problems)
    #expect(exists(old))
    #expect(try Data(contentsOf: URL(fileURLWithPath: there, isDirectory: false)) == before)
    #expect(exists(folders.library + "/Loose"))
}

@Test func twoFilesWithOnePathMoveTheFirstAndListTheSecond() throws {
    let folders = try OrganizeFolders()
    let one = try folders.file("library/a.flac", title: "Song")
    let two = try folders.file("library/b.flac", title: "Song")
    let new = folders.library + "/Artist/Album/01 Song.flac"
    let planned = layoutMoves([one, two], libraryFolder: folders.library)
    #expect(planned.moved == [TrackMove(from: one, to: new)])
    let result = folders.organize([one, two])
    #expect(result.moved == [TrackMove(from: one, to: new)])
    #expect(result.problems == ["\(two): not moved, already in the library: \(new)"])
    #expect(exists(two))
}

@Test func aFileOutsideTheLibraryFolderIsNeverMoved() throws {
    let folders = try OrganizeFolders()
    let outside = try folders.file("elsewhere/song.flac", title: "Song")
    let linked = folders.library + "/linked.flac"
    try FileManager.default.createSymbolicLink(atPath: linked, withDestinationPath: outside)
    let result = folders.organize([outside, linked])
    #expect(result.moved.isEmpty)
    #expect(result.outside == [outside, linked])
    #expect(exists(outside))
    #expect(result.problemLines.first == "\(outside) isn't inside the library folder")
}

@Test func coverArtKeepsTheOldFolderAndIsListed() throws {
    let folders = try OrganizeFolders()
    let old = try folders.file("library/Old/song.flac", title: "Song")
    let cover = folders.library + "/Old/cover.jpg"
    #expect(FileManager.default.createFile(atPath: cover, contents: Data("jpeg".utf8)))
    let result = folders.organize([old])
    #expect(result.moved.count == 1)
    #expect(exists(cover))
    #expect(exists(folders.library + "/Old"))
    #expect(result.keptFolders == [folders.library + "/Old"])
}

@Test func aFolderWithAudioLeftInItIsKeptAndNotListed() throws {
    let folders = try OrganizeFolders()
    let old = try folders.file("library/Old/song.flac", title: "Song")
    let stays = try folders.file("library/Old/stays.flac", title: "Stays")
    let result = folders.organize([old])
    #expect(result.moved.count == 1)
    #expect(exists(stays))
    #expect(result.keptFolders.isEmpty)
}

@Test func anotherVolumeSkipsTheFileRatherThanCopyIt() throws {
    let folders = try OrganizeFolders()
    let old = try folders.file("library/song.flac", title: "Song")
    var calls = MoveCalls()
    calls.renameExclusive = { _, _ in EXDEV }
    calls.rename = { _, _ in
        Issue.record("no plain rename after EXDEV")
        return 0
    }
    let result = folders.organize([old], calls)
    #expect(result.moved.isEmpty)
    #expect(result.problems.first?.contains("is on another volume") == true)
    #expect(exists(old))
}

@Test func aShareThatRefusesRenameExclGetsTheSameFallbackAsApprove() throws {
    let folders = try OrganizeFolders()
    let old = try folders.file("library/song.flac", title: "Song")
    var calls = MoveCalls()
    calls.renameExclusive = { _, _ in ENOTSUP }
    let result = folders.organize([old], calls)
    #expect(result.moved.map(\.to) == [folders.library + "/Artist/Album/01 Song.flac"])
    #expect(!exists(old))
}

@Test func theOrganizedMovesCarryStatsAndPlaylistsThroughTheMoveList() throws {
    let folders = try OrganizeFolders()
    let old = try folders.file("library/Old/song.flac", title: "Song")
    let index = try craftedIndex([Crafted(path: old, title: "Song").scanned])
    let id = try #require(try index.track(path: old)).id
    try index.recordPlay(old, at: 1_700_000_000)
    try index.setRating(4, trackIDs: [id])
    let playlist = try index.createPlaylist(named: "Mix")
    _ = try index.addToPlaylist(playlist, trackIDs: [id])

    let result = folders.organize([old])
    let carried = try index.importMoves(
        MoveList(moves: result.moved.map { ($0.from, $0.to) }))
    #expect(carried == MoveListImport(moved: 1))
    let new = try #require(result.moved.first?.to)
    #expect(try index.existingPathID(new) == id)
    #expect(try index.existingPathID(old) == nil)
    #expect(try index.playlistTrackIDs(playlist) == [id])
}

/// Whether the library folder's volume ignores case, as the temp directory's usually does.
private func ignoresCase(_ folder: String) -> Bool { pathconf(folder, _PC_CASE_SENSITIVE) == 0 }

@Test func oneBatchSpellsAFolderOneWayOnAVolumeThatIgnoresCase() throws {
    let folders = try OrganizeFolders()
    guard ignoresCase(folders.library) else { return }
    let one = try folders.file("library/a.flac", title: "One", artist: "Artist", track: 1)
    let two = try folders.file("library/b.flac", title: "Two", artist: "ARTIST", track: 2)
    let result = folders.organize([one, two])
    #expect(
        result.moved.map(\.to) == [
            folders.library + "/Artist/Album/01 One.flac",
            folders.library + "/Artist/Album/02 Two.flac",
        ])
    #expect(try FileManager.default.contentsOfDirectory(atPath: folders.library) == ["Artist"])
}

@Test func twoNamesTheVolumeHoldsToBeOneAreOneDestination() throws {
    let folders = try OrganizeFolders()
    guard ignoresCase(folders.library) else { return }
    let one = try folders.file("library/a.flac", title: "Song", artist: "Artist")
    let two = try folders.file("library/b.flac", title: "SONG", artist: "artist")
    let plan = layoutMoves([one, two], libraryFolder: folders.library)
    #expect(plan.moved.map(\.from) == [one])
    #expect(plan.problems.count == 1)
}

@Test func aFailedRenameRemovesTheFoldersItMadeForTheFile() throws {
    let folders = try OrganizeFolders()
    let old = try folders.file("library/song.flac", title: "Song")
    try FileManager.default.createDirectory(
        atPath: folders.library + "/Artist", withIntermediateDirectories: true)
    try Data().write(to: URL(fileURLWithPath: folders.library + "/Artist/kept.txt"))
    var calls = MoveCalls()
    calls.renameExclusive = { _, _ in EIO }
    let result = folders.organize([old], calls)
    #expect(result.moved.isEmpty)
    #expect(result.problems.count == 1)
    #expect(!exists(folders.library + "/Artist/Album"))
    #expect(exists(folders.library + "/Artist/kept.txt"))
    #expect(exists(old))
}

@Test func aFileReachedThroughALinkedSpellingOfTheFolderIsInPlace() throws {
    let folders = try OrganizeFolders()
    let path = try folders.file("library/Artist/Album/01 Song.flac", title: "Song")
    let linked = folders.root + "/linked"
    try FileManager.default.createSymbolicLink(
        atPath: linked, withDestinationPath: folders.library)
    let result = moveToLayout(
        layoutMoves([path], libraryFolder: linked), libraryFolder: linked)
    #expect(result.inPlace == 1)
    #expect(result.problems.isEmpty)
    #expect(exists(path))
}
