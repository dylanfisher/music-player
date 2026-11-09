import Darwin
import Foundation
import Testing

@testable import Library
@testable import Metadata

/// The database file behind `index`, which `carryLayoutMoves` opens itself.
private func databaseURL(_ index: LibraryIndex) -> URL {
    index.fileURL
}

private struct CarryFailed: Error, CustomStringConvertible {
    var description: String { "the index is locked" }
}

@Test func everyMoveIsRecordedBeforeTheFirstRename() throws {
    let folders = try OrganizeFolders()
    let old = try folders.file("library/song.flac", title: "Song")
    let url = folders.index.fileURL
    var calls = MoveCalls()
    calls.renameExclusive = { from, to in
        #expect((try? LibraryIndex(at: url).layoutMoves()) == [TrackMove(from: from, to: to)])
        return Darwin.rename(from, to) == 0 ? 0 : errno
    }
    let result = folders.organize([old], calls)
    #expect(result.moved.count == 1)
    #expect(try folders.index.layoutMoves() == result.moved)
}

@Test func aMoveWhoseRenameFailedIsDropped() throws {
    let folders = try OrganizeFolders()
    let old = try folders.file("library/song.flac", title: "Song")
    var calls = MoveCalls()
    calls.renameExclusive = { _, _ in EIO }
    _ = folders.organize([old], calls)
    #expect(try folders.index.layoutMoves().isEmpty)
}

@Test func aCarryThatFailsKeepsTheMovesAndNamesEachOne() async throws {
    let folders = try OrganizeFolders()
    let old = try folders.file("library/song.flac", title: "Song")
    let moved = folders.organize([old]).moved
    let url = databaseURL(folders.index)

    let failed = await carryLayoutMoves(databaseURL: url) { _ in throw CarryFailed() }
    let move = try #require(moved.first)
    #expect(
        failed.problems == [
            "the stats of \(move.from) didn't follow it to \(move.to): the index is locked;"
                + " they follow it at the next launch"
        ])
    #expect(try folders.index.layoutMoves() == moved)

    let lines = LinesSeen()
    let again = await carryLayoutMoves(databaseURL: url) { carried in
        lines.add(carried.map { TrackMove(from: $0.from, to: $0.to) })
        return MoveListImport(moved: carried.count)
    }
    #expect(again.carried == moved)
    #expect(again.problems.isEmpty)
    #expect(lines.all == moved)
    #expect(try folders.index.layoutMoves().isEmpty)
}

@Test func aLineTheMoveListRefusedIsNamedAndTheRestCarried() async throws {
    let folders = try OrganizeFolders()
    let one = try folders.file("library/a.flac", title: "One", track: 1)
    let two = try folders.file("library/b.flac", title: "Two", track: 2)
    let moved = folders.organize([one, two]).moved
    #expect(moved.count == 2)
    let result = await carryLayoutMoves(databaseURL: databaseURL(folders.index)) { lines in
        MoveListImport(
            moved: lines.count - 1,
            problems: [MoveListProblem(line: 2, reason: "the old path isn't in the library")])
    }
    #expect(result.carried == [moved[0]])
    #expect(
        result.problems == [
            "the stats of \(moved[1].from) didn't follow it to \(moved[1].to): the old path"
                + " isn't in the library"
        ])
    #expect(try folders.index.layoutMoves().isEmpty)
}

@Test func atLaunchAMoveThatNeverHappenedIsDroppedAndOneThatDidIsCarried() async throws {
    let folders = try OrganizeFolders()
    let stayed = try folders.file("library/stayed.flac", title: "Stayed")
    let renamed = try folders.file("library/Artist/Album/01 Renamed.flac", title: "Renamed")
    // As a crash leaves them: one recorded before its rename, one after.
    try folders.index.recordLayoutMoves([
        TrackMove(from: stayed, to: folders.library + "/Artist/Album/01 Stayed.flac"),
        TrackMove(from: folders.library + "/renamed.flac", to: renamed),
    ])
    let lines = LinesSeen()
    let result = await carryLayoutMoves(databaseURL: databaseURL(folders.index)) { carried in
        lines.add(carried.map { TrackMove(from: $0.from, to: $0.to) })
        return MoveListImport(moved: carried.count)
    }
    #expect(lines.all == [TrackMove(from: folders.library + "/renamed.flac", to: renamed)])
    #expect(result.problems.isEmpty)
    #expect(try folders.index.layoutMoves().isEmpty)
}

@Test func theStatsFollowThroughTheRealMoveList() async throws {
    let folders = try OrganizeFolders()
    let old = try folders.file("library/Old/song.flac", title: "Song")
    try folders.index.store([Crafted(path: old, title: "Song").scanned])
    let id = try #require(try folders.index.track(path: old)).id
    try folders.index.recordPlay(old, at: 1_700_000_000)
    let moved = folders.organize([old]).moved
    let url = databaseURL(folders.index)
    let result = await carryLayoutMoves(databaseURL: url) { lines in
        try LibraryIndex(at: url).importMoves(MoveList(moves: lines))
    }
    #expect(result.carried == moved)
    #expect(try folders.index.existingPathID(try #require(moved.first).to) == id)
}

/// The lines each carry was handed, from the carry's thread.
private final class LinesSeen: @unchecked Sendable {
    // `lines` is guarded by `lock`.
    private let lock = NSLock()
    private var lines: [TrackMove] = []
    func add(_ more: [TrackMove]) { lock.withLock { lines += more } }
    var all: [TrackMove] { lock.withLock { lines } }
}
