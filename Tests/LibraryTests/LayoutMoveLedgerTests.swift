import Darwin
import Foundation
import Testing

@testable import Library
@testable import Metadata

/// The database file behind `index`, which `carryLayoutMoves` opens itself.
private func databaseURL(_ index: LibraryIndex) -> URL {
    index.fileURL
}

/// Stands in for the tag writes' queue, which the organizer and the carry share.
private final class WriteQueue: Sendable {
    let queue = DispatchQueue(label: "layout-move-ledger-tests")

    @Sendable func run(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            queue.async {
                work()
                continuation.resume()
            }
        }
    }
}

private let writes = WriteQueue()

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

    let failed = await carryLayoutMoves(databaseURL: url, serially: writes.run) { _ in
        throw CarryFailed()
    }
    let move = try #require(moved.first)
    #expect(
        failed.problems == [
            "the stats of \(move.from) didn't follow it to \(move.to): the index is locked;"
                + " they follow it at the next launch"
        ])
    #expect(try folders.index.layoutMoves() == moved)

    let lines = LinesSeen()
    let again = await carryLayoutMoves(databaseURL: url, serially: writes.run) { carried in
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
    let result = await carryLayoutMoves(
        databaseURL: databaseURL(folders.index), serially: writes.run
    ) { lines in
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
    let result = await carryLayoutMoves(
        databaseURL: databaseURL(folders.index), serially: writes.run
    ) { carried in
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
    let result = await carryLayoutMoves(databaseURL: url, serially: writes.run) { lines in
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

/// Holds a rename until the test lets it go.
private final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func wait() { semaphore.wait() }
    func open() { semaphore.signal() }
}

@Test func aCarryDuringAnOrganizeWaitsForItsRenames() async throws {
    let folders = try OrganizeFolders()
    let old = try folders.file("library/song.flac", title: "Song")
    let plan = layoutMoves([old], libraryFolder: folders.library)
    let url = folders.index.fileURL
    let library = folders.library
    let recorded = Gate()
    let renaming = Gate()
    var calls = MoveCalls()
    calls.renameExclusive = { from, to in
        // The moves are recorded; the carry starts here, and the rename waits for it to try.
        recorded.open()
        renaming.wait()
        return Darwin.rename(from, to) == 0 ? 0 : errno
    }
    let renames = calls
    let organized = Task {
        await writes.run {
            _ = moveToLayout(
                plan, libraryFolder: library, ledger: { try LibraryIndex(at: url) },
                calls: renames)
        }
    }
    recorded.wait()
    let carrying = Task {
        await carryLayoutMoves(databaseURL: url, serially: writes.run) { lines in
            MoveListImport(moved: lines.count)
        }
    }
    // Long enough for a carry that doesn't wait to read the ledger and drop the move.
    try await Task.sleep(nanoseconds: 200_000_000)
    renaming.open()
    await organized.value
    let result = await carrying.value
    #expect(result.carried == plan.moved)
    #expect(result.problems.isEmpty)
    #expect(try folders.index.layoutMoves().isEmpty)
}
