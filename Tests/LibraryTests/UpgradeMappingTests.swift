import Foundation
import Testing

@testable import Library
@testable import Metadata

private let share = "smb://HAL9000/music"

private func old(_ name: String, _ position: String?, stats: Bool = false) -> UpgradeOldFile {
    UpgradeOldFile(
        sharePath: "library/A/" + name, path: "/Volumes/music/library/A/" + name,
        position: position, hasStats: stats, release: "42")
}

@Test func oldFilesPairWithTheNewFileAtTheirPosition() {
    let mapping = UpgradeMapping(
        old: [old("01.mp3", "A1"), old("02.mp3", "A2"), old("03.mp3", "B1")],
        new: [("02.flac", "A2"), ("01.flac", "A1"), ("03.flac", "B1"), ("04.flac", "B2")])
    #expect(
        mapping.pairs == [
            .init(old: "library/A/01.mp3", new: "01.flac"),
            .init(old: "library/A/02.mp3", new: "02.flac"),
            .init(old: "library/A/03.mp3", new: "03.flac"),
        ])
    #expect(mapping.unmatched.isEmpty)
}

@Test func anOldFileWithNoCounterpartIsUnmatchedWithItsStats() {
    let unplaced = old("00.mp3", nil, stats: true)
    let missing = old("03.mp3", "B1", stats: true)
    let twin = old("01 again.mp3", "A1")
    let mapping = UpgradeMapping(
        old: [unplaced, old("01.mp3", "A1"), twin, missing],
        new: [("01.flac", "A1"), ("02.flac", nil)])
    #expect(mapping.pairs == [.init(old: "library/A/01.mp3", new: "01.flac")])
    #expect(mapping.unmatched == [unplaced, twin, missing])
}

/// A temporary share mounted at `root`, its `library` folder found there, holding an MP3
/// album of release 42 whose first track was played, rated, loved and put in "Mix".
private final class UpgradeLibrary {
    let root: String
    let databaseURL: URL
    let index: LibraryIndex
    let playlist: Int64
    let played: Int64

    init() throws {
        let root =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("upgrade-\(UUID().uuidString)").path
        self.root = root
        databaseURL = URL(fileURLWithPath: root + ".sqlite", isDirectory: false)
        try FileManager.default.createDirectory(
            atPath: root + "/library/A", withIntermediateDirectories: true)
        index = try LibraryIndex(at: databaseURL)
        try index.relocate(share: share, path: "library", to: root + "/library")
        try index.store(
            [("01.mp3", "42"), ("02.mp3", "42"), ("03.mp3", "7")].map { name, release in
                Crafted(
                    path: root + "/library/A/" + name, title: name, album: "A", codec: .mp3,
                    custom: [DiscogsKey.releaseID: release]
                ).scanned
            })
        played = try #require(try index.track(path: root + "/library/A/01.mp3")).id
        try index.recordPlay(root + "/library/A/01.mp3", at: 1_700_000_000)
        try index.setRating(4, trackIDs: [played])
        try index.toggle(.liked, trackIDs: [played])
        playlist = try index.createPlaylist(named: "Mix")
        _ = try index.addToPlaylist(playlist, trackIDs: [played])
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
        try? FileManager.default.removeItem(at: databaseURL)
    }

    func path(_ name: String) -> String { root + "/library/A/" + name }

    /// The new file at `name`, on disk as an upgrade leaves it. The old files never are.
    func create(_ name: String) throws {
        #expect(FileManager.default.createFile(atPath: path(name), contents: Data()))
    }

    func moves() throws -> [SyncEvent] {
        try index.database.prepare("SELECT line FROM \(syncOutboxTable)").map {
            try SyncRecord(line: Array(try $0.text(0).utf8)[...]).event
        }.filter { if case .move = $0 { true } else { false } }
    }
}

@Test func theOldFilesAreFoundByTheirSharePathWithTheirStats() throws {
    let library = try UpgradeLibrary()
    let found = try library.index.upgradeOldFiles(
        ["library/A/01.mp3", "library/A/02.mp3"], release: 42, shareRoot: library.root)
    #expect(
        found == [
            UpgradeOldFile(
                sharePath: "library/A/01.mp3", path: library.path("01.mp3"), position: nil,
                hasStats: true, release: "42"),
            UpgradeOldFile(
                sharePath: "library/A/02.mp3", path: library.path("02.mp3"), position: nil,
                hasStats: false, release: "42"),
        ])
}

@Test func anOldFileOfAnotherReleaseOrNotInTheLibraryIsRefused() throws {
    let library = try UpgradeLibrary()
    #expect(
        throws: UpgradeRefusal.otherRelease(library.path("03.mp3"), found: "7", expected: "42")
    ) {
        try library.index.upgradeOldFiles(
            ["library/A/01.mp3", "library/A/03.mp3"], release: 42, shareRoot: library.root)
    }
    // Held to the release it carried, it passes; held to none, it doesn't.
    #expect(
        try library.index.upgradeOldFiles(
            ["library/A/03.mp3"], release: 42, held: ["library/A/03.mp3": "7"],
            shareRoot: library.root
        ).map(\.release) == ["7"])
    #expect(throws: UpgradeRefusal.otherRelease(library.path("03.mp3"), found: "7", expected: nil))
    {
        try library.index.upgradeOldFiles(
            ["library/A/03.mp3"], release: 42, held: ["library/A/03.mp3": nil],
            shareRoot: library.root)
    }
    #expect(throws: UpgradeRefusal.notInLibrary(library.path("09.mp3"))) {
        try library.index.upgradeOldFiles(
            ["library/A/09.mp3"], release: 42, shareRoot: library.root)
    }
}

/// Expects the track at `name` to hold the stats `UpgradeLibrary` gave the first old track.
private func expectStats(_ library: UpgradeLibrary, at name: String) throws {
    let track = try #require(try library.index.track(path: library.path(name)))
    #expect(track.id == library.played)
    #expect(track.playCount == 1)
    #expect(track.rating == 4)
    #expect(track.loved)
    #expect(try library.index.playlistTrackIDs(library.playlist) == [library.played])
    #expect(
        try library.moves() == [
            .move(from: "music/library/A/01.mp3", to: "music/library/A/01.flac")
        ])
}

@Test func importMovesByLinesCarriesPlaysRatingsAndPlaylistsAndLogsTheMove() async throws {
    let library = try UpgradeLibrary()
    try library.create("01.flac")
    try library.index.store([Crafted(path: library.path("01.flac"), title: "01").scanned])
    let watcher = LibraryWatcher(databaseURL: library.databaseURL, networkReaders: nil)
    let result = try await watcher.importMoves(lines: [
        (from: library.path("01.mp3"), to: library.path("01.flac"))
    ])
    #expect(result == MoveListImport(moved: 1))
    try expectStats(library, at: "01.flac")
}

@Test func importMovesStillFindsTheOldPathAfterForgetTrashed() async throws {
    let library = try UpgradeLibrary()
    try library.create("01.flac")
    try library.index.forgetTrashed(trackIDs: [library.played])
    #expect(try library.index.track(path: library.path("01.mp3")) == nil)
    let watcher = LibraryWatcher(databaseURL: library.databaseURL, networkReaders: nil)
    let result = try await watcher.importMoves(lines: [
        (from: library.path("01.mp3"), to: library.path("01.flac"))
    ])
    #expect(result == MoveListImport(moved: 1))
    // No scan has read the new file yet: the stats wait on its path for the scan.
    try library.index.store([Crafted(path: library.path("01.flac"), title: "01").scanned])
    try expectStats(library, at: "01.flac")
}

@Test func aMoveListOfLinesRefusesAPathWithATab() {
    let list = MoveList(moves: [(from: "/a\tb", to: "/c"), (from: "/d", to: "/e")])
    #expect(list.lines.map(\.from) == ["/d"])
    #expect(list.problems.map(\.line) == [1])
}
