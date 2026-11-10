import Foundation
import Testing

@testable import Library
@testable import Metadata
@testable import Settings

/// A temporary folder standing in for the library on disk, with an index of crafted tracks
/// whose paths are in it. Only the new files a move list names need to exist; they're empty.
private final class MoveListLibrary {
    let root: String
    let index: LibraryIndex

    init() throws {
        root =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("moves-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        index = try craftedIndex([])
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    func path(_ name: String) -> String { root + "/" + name }

    /// Puts an empty file at `name`, as the converted file stands on disk.
    func create(_ name: String) throws {
        let path = path(name)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: path, contents: Data()))
    }

    /// Stores a track at `name`, as a scan that read it would.
    @discardableResult
    func scanned(_ name: String, codec: TrackAudio.Codec = .flac, seconds: Double = 200) throws
        -> Int64
    {
        try index.store([
            Crafted(path: path(name), title: name, seconds: seconds, codec: codec).scanned
        ])
        return try #require(try index.track(path: path(name))).id
    }

    /// An ALAC track at `name`, played once, rated, loved, in the playlist "Mix" and added at
    /// 1000; with `gone`, a scan has found its file gone since.
    @discardableResult
    func played(_ name: String, gone: Bool = true) throws -> Int64 {
        let id = try scanned(name, codec: .alac)
        try index.recordPlay(path(name), at: 1_700_000_000)
        try index.setRating(4, trackIDs: [id])
        try index.toggle(.liked, trackIDs: [id])
        let playlist =
            try index.playlists().first { $0.name == "Mix" }?.id
            ?? index.createPlaylist(named: "Mix")
        _ = try index.addToPlaylist(playlist, trackIDs: [id])
        try index.database.prepare("UPDATE paths SET added_seconds = 1000 WHERE id = ?").run(id)
        if gone { try index.remove([id]) }
        return id
    }

    /// Writes `text` as a move list beside the library and imports it.
    func importList(_ text: String) throws -> MoveListImport {
        let list = URL(fileURLWithPath: root + ".moves", isDirectory: false)
        try Data(text.utf8).write(to: list)
        defer { try? FileManager.default.removeItem(at: list) }
        return try index.importMoves(from: list)
    }

    /// Imports a list of `pairs`, by name.
    func importMoves(_ pairs: [(String, String)]) throws -> MoveListImport {
        try importList(pairs.map { path($0.0) + "\t" + path($0.1) + "\n" }.joined())
    }

    func track(_ name: String) throws -> TrackRow? { try index.track(path: path(name)) }

    func history(_ name: String) throws -> Int {
        try index.database.prepare(
            "SELECT count(*) FROM history h JOIN paths p ON p.id = h.path_id WHERE p.path = ?"
        ).map(path(name).precomposedStringWithCanonicalMapping) { try $0.int(0) }[0]
    }

    func mix() throws -> [Int64] {
        try index.playlistTrackIDs(try #require(try index.playlists().first?.id))
    }
}

/// Expects the track at `name` to have the stats `played` gave the path `id`, under that ID.
private func expectStats(_ library: MoveListLibrary, _ name: String, id: Int64) throws {
    let track = try #require(try library.track(name))
    #expect(track.id == id)
    #expect(track.playCount == 1)
    #expect(track.rating == 4)
    #expect(track.loved)
    #expect(track.addedSeconds == 1000)
    #expect(try library.history(name) == 1)
    #expect(try library.mix() == [id])
    #expect(try library.index.lostFiles().isEmpty)
    #expect(try library.index.matchMoves().isEmpty)
}

@Test func aMoveListGivesAGonePathsStatsToTheTrackAtItsNewPath() throws {
    let library = try MoveListLibrary()
    let old = try library.played("A/01.m4a")
    try library.create("A/01.flac")
    try library.scanned("A/01.flac")
    #expect(try library.importMoves([("A/01.m4a", "A/01.flac")]) == MoveListImport(moved: 1))
    try expectStats(library, "A/01.flac", id: old)
    #expect(try library.index.existingPathID(library.path("A/01.m4a")) == nil)
}

@Test func aMoveAScanAlreadyMatchedIsAlreadyDone() throws {
    let library = try MoveListLibrary()
    let old = try library.played("A/01.m4a")
    try library.create("A/01.flac")
    try library.scanned("A/01.flac")
    #expect(try library.index.matchMoves().count == 1)
    #expect(try library.importMoves([("A/01.m4a", "A/01.flac")]) == MoveListImport(alreadyDone: 1))
    try expectStats(library, "A/01.flac", id: old)
}

@Test func aListImportedTwiceMovesOnce() throws {
    let library = try MoveListLibrary()
    let old = try library.played("A/01.m4a")
    try library.create("A/01.flac")
    try library.scanned("A/01.flac")
    #expect(try library.importMoves([("A/01.m4a", "A/01.flac")]).moved == 1)
    #expect(try library.importMoves([("A/01.m4a", "A/01.flac")]) == MoveListImport(alreadyDone: 1))
    try expectStats(library, "A/01.flac", id: old)
}

@Test func aMoveOfATrackWithNoStatsImportedTwiceInAShareFolderIsAlreadyDone() throws {
    let library = try MoveListLibrary()
    try library.index.relocate(share: "smb://HAL9000/music", path: "library", to: library.root)
    let old = try library.scanned("A/01.m4a", codec: .alac)
    try library.index.remove([old])
    try library.create("A/01.flac")
    try library.scanned("A/01.flac")
    #expect(try library.importMoves([("A/01.m4a", "A/01.flac")]) == MoveListImport(moved: 1))
    #expect(try library.importMoves([("A/01.m4a", "A/01.flac")]) == MoveListImport(alreadyDone: 1))
    #expect(try library.index.existingPathID(library.path("A/01.flac")) == old)
}

@Test func aMoveBeforeAnyScanLetsTheOldFileGoAndTheStatsWaitForTheNewOne() throws {
    let library = try MoveListLibrary()
    // No scan since the conversion: the index still has the old file and not the new one.
    let old = try library.played("A/01.m4a", gone: false)
    try library.create("A/01.flac")
    #expect(try library.importMoves([("A/01.m4a", "A/01.flac")]) == MoveListImport(moved: 1))
    #expect(try library.track("A/01.m4a") == nil)
    #expect(
        try library.index.database.prepare("SELECT count(*) FROM files").map { try $0.int(0) }
            == [0])
    #expect(try library.index.existingPathID(library.path("A/01.flac")) == old)
    // The scan finds the new file, under the row holding the stats, and nothing gone.
    try library.scanned("A/01.flac")
    try expectStats(library, "A/01.flac", id: old)
}

@Test func aMoveBeforeTheOldFolderIsScannedButAfterTheNewOneIs() throws {
    let library = try MoveListLibrary()
    let old = try library.played("A/01.m4a", gone: false)
    try library.create("B/01.flac")
    try library.scanned("B/01.flac")
    #expect(try library.importMoves([("A/01.m4a", "B/01.flac")]) == MoveListImport(moved: 1))
    try expectStats(library, "B/01.flac", id: old)
}

@Test func aMoveToAPathNoScanHasSeenWaitsThereForTheScan() throws {
    let library = try MoveListLibrary()
    let old = try library.played("A/01.m4a")
    try library.create("A/01.flac")
    #expect(try library.importMoves([("A/01.m4a", "A/01.flac")]) == MoveListImport(moved: 1))
    #expect(try library.index.existingPathID(library.path("A/01.flac")) == old)
    // Until the scan reads it, the path isn't lost, and no other track can take its stats.
    try library.scanned("B/same length.flac")
    #expect(try library.index.lostFiles().isEmpty)
    #expect(try library.index.matchMoves().isEmpty)
    try library.scanned("A/01.flac")
    try expectStats(library, "A/01.flac", id: old)
}

@Test func aMoveOntoAPathWithStatsOfItsOwnMergesThem() throws {
    let library = try MoveListLibrary()
    let old = try library.played("A/01.m4a")
    try library.create("A/01.flac")
    try library.scanned("A/01.flac")
    try library.index.recordPlay(library.path("A/01.flac"), at: 1_700_000_500)
    #expect(try library.importMoves([("A/01.m4a", "A/01.flac")]) == MoveListImport(merged: 1))
    let track = try #require(try library.track("A/01.flac"))
    #expect(track.id == old)
    #expect(track.playCount == 2)
    #expect(track.rating == 4)
    #expect(track.loved)
    #expect(track.addedSeconds == 1000)
    #expect(try library.history("A/01.flac") == 2)
    #expect(try library.mix() == [old])
    #expect(try library.index.lostFiles().isEmpty)
}

@Test func importingBeforeOrAfterTheScanEndsTheSame() throws {
    func ending(scanFirst: Bool) throws -> [String] {
        let library = try MoveListLibrary()
        try library.played("A/01.m4a", gone: !scanFirst)
        try library.played("A/02.m4a", gone: !scanFirst)
        for name in ["A/01.flac", "A/02.flac"] { try library.create(name) }
        // Two converted files of one length, which the scan's own matching tells apart by path.
        func scan() throws {
            if scanFirst {
                try library.index.remove(
                    try ids(library.index, [library.path("A/01.m4a"), library.path("A/02.m4a")]))
            }
            try library.scanned("A/01.flac")
            try library.scanned("A/02.flac")
            _ = try library.index.matchMoves()
        }
        let list = [("A/01.m4a", "A/01.flac"), ("A/02.m4a", "A/02.flac")]
        if scanFirst {
            try scan()
            #expect(try library.importMoves(list).alreadyDone == 2)
        } else {
            #expect(try library.importMoves(list).moved == 2)
            try scan()
        }
        return try library.index.database.prepare(
            """
            SELECT substr(p.path, length(?) + 1), p.id, p.added_seconds, pl.play_count,
                (SELECT count(*) FROM history WHERE path_id = p.id), f.id IS NOT NULL
            FROM paths p LEFT JOIN plays pl ON pl.path_id = p.id LEFT JOIN files f ON f.id = p.id
            ORDER BY p.path
            """
        ).map(library.root) { row in
            (0..<6).map { row.optionalText(Int32($0)) ?? "null" }.joined(separator: " ")
        }
    }
    let before = try ending(scanFirst: false)
    #expect(before.count == 2)
    #expect(before == (try ending(scanFirst: true)))
}

@Test func aBadLineIsAProblemAndTheGoodLinesStillMove() throws {
    let library = try MoveListLibrary()
    let one = try library.played("A/01.m4a")
    let two = try library.played("A/02.m4a")
    try library.played("A/03.m4a", gone: false)
    try library.create("A/03.m4a")
    for name in ["A/01.flac", "A/02.flac", "A/03.flac", "A/05.flac"] {
        try library.create(name)
    }
    let p = library.path
    let result = try library.importList(
        [
            p("A/01.m4a") + "\t" + p("A/01.flac"),
            "no tab here",
            p("A/02.m4a") + "\t" + p("A/02.flac") + "\tthird",
            "relative.m4a\t" + p("A/01.flac"),
            p("A/04.m4a") + "\t" + p("A/04.flac"),
            p("A/03.m4a") + "\t" + p("A/03.flac"),
            p("A/05.m4a") + "\t" + p("A/05.flac"),
            p("A/01.flac") + "\t" + p("A/01.flac"),
            "",
            p("A/02.m4a") + "\t" + p("A/02.flac"),
        ].joined(separator: "\n") + "\n" + p("A/06.m4a") + "\t" + p("A/06"))
    #expect(result.moved == 2)
    #expect(result.problems.map(\.line) == [2, 3, 4, 5, 6, 7, 8, 9, 11])
    #expect(result.problems[0].reason.contains("0 tabs"))
    #expect(result.problems[1].reason.contains("2 tabs"))
    #expect(result.problems[2].reason.contains("absolute"))
    #expect(result.problems[3].reason.contains("A/04.flac isn't there"))
    #expect(result.problems[4].reason.contains("A/03.m4a is still there"))
    #expect(result.problems[5].reason.contains("A/05.m4a isn't in the library"))
    #expect(result.problems[6].reason.contains("are the same"))
    #expect(result.problems[8].reason.contains("doesn't end in a newline"))
    #expect(result.problems[0].description.hasPrefix("line 2: "))
    #expect(try library.index.existingPathID(library.path("A/01.flac")) == one)
    #expect(try library.index.existingPathID(library.path("A/02.flac")) == two)
    // The old file still there keeps its stats where they were.
    #expect(try library.track("A/03.m4a")?.playCount == 1)
}

@Test func aLineThatIsntUTF8IsAProblem() throws {
    let library = try MoveListLibrary()
    let list = URL(fileURLWithPath: library.root + ".moves", isDirectory: false)
    try Data([0x2F, 0xFF, 0x09, 0x2F, 0x61, 0x0A]).write(to: list)
    defer { try? FileManager.default.removeItem(at: list) }
    #expect(
        try library.index.importMoves(from: list)
            == MoveListImport(problems: [MoveListProblem(line: 1, reason: "it isn't UTF-8 text")]))
}

@Test func aListSpelledInTheOtherUnicodeFormStillMoves() throws {
    let library = try MoveListLibrary()
    let decomposed = "Cafe\u{301}/Ame\u{301}lie"
    let precomposed = "Caf\u{e9}/Am\u{e9}lie"
    // Scanned decomposed, as SMB lists it; the list spells the old path precomposed.
    let one = try library.played(decomposed + " 1.m4a")
    let two = try library.played(precomposed + " 2.m4a")
    try library.create(decomposed + " 1.flac")
    try library.create(precomposed + " 2.flac")
    try library.scanned(precomposed + " 1.flac")
    try library.scanned(decomposed + " 2.flac")
    #expect(
        try library.importMoves([
            (precomposed + " 1.m4a", decomposed + " 1.flac"),
            (decomposed + " 2.m4a", precomposed + " 2.flac"),
        ]) == MoveListImport(moved: 2))
    #expect(try library.track(precomposed + " 1.flac")?.id == one)
    #expect(try library.track(decomposed + " 2.flac")?.id == two)
}

@Test func anImportedMoveIsLoggedForTheOtherMacs() throws {
    let library = try MoveListLibrary()
    // The library folder is a share's `library` folder, mounted at the temporary folder.
    _ = try library.index.locate(
        [WatchedFolder(path: "library", share: "smb://nas/music", kind: .network)],
        among: [MountedShare(url: "smb://nas/music", mountPoint: library.root)])
    try library.played("library/A/01.m4a")
    try library.create("library/A/01.flac")
    try library.scanned("library/A/01.flac")
    #expect(try library.importMoves([("library/A/01.m4a", "library/A/01.flac")]).moved == 1)
    let lines = try library.index.database.prepare("SELECT line FROM \(syncOutboxTable)").map {
        try $0.text(0)
    }
    let moves = try lines.map { try SyncRecord(line: Array($0.utf8)[...]).event }.filter {
        if case .move = $0 { true } else { false }
    }
    #expect(moves == [.move(from: "music/library/A/01.m4a", to: "music/library/A/01.flac")])
    #expect(
        try library.index.resolvedSyncPath("music/library/A/01.m4a")
            == "music/library/A/01.flac")
}

@Test func aLongListMovesInLinearTime() throws {
    let library = try MoveListLibrary()
    let count = 5 * moveListBatchLines + 500
    let names = (0..<count).map { "A/\($0 / 12)/\($0)" }
    try library.index.store(
        names.enumerated().map { offset, name in
            Crafted(path: library.path(name + ".m4a"), seconds: Double(offset + 1), codec: .alac)
                .scanned
        })
    let olds = try ids(library.index, names.map { library.path($0 + ".m4a") })
    try library.index.setRating(3, trackIDs: olds)
    try library.index.remove(olds)
    // Half the new files a scan has seen, half it hasn't.
    try library.index.store(
        names.enumerated().filter { $0.offset.isMultiple(of: 2) }.map { offset, name in
            Crafted(path: library.path(name + ".flac"), seconds: Double(offset + 1)).scanned
        })
    for name in names { try library.create(name + ".flac") }

    let clock = ContinuousClock()
    var result = MoveListImport()
    let elapsed = try clock.measure {
        result = try library.importMoves(names.map { ($0 + ".m4a", $0 + ".flac") })
    }
    print("imported \(count) moves in \(elapsed)")
    #expect(result == MoveListImport(moved: count))
    // About 1 ms a line here; a quadratic import would take minutes.
    #expect(elapsed < .seconds(30))
    #expect(try library.track(names[0] + ".flac")?.rating == 3)
    // The stats moved to a path no scan has read wait there, not lost.
    #expect(try library.index.lostFiles().isEmpty)
    try library.index.store(
        names.enumerated().filter { !$0.offset.isMultiple(of: 2) }.map { offset, name in
            Crafted(path: library.path(name + ".flac"), seconds: Double(offset + 1)).scanned
        })
    #expect(try library.track(names[1] + ".flac")?.id == olds[1])
    #expect(try library.track(names[1] + ".flac")?.rating == 3)
}
