import Foundation
import Testing

@testable import Library
@testable import Snapshot

private func names(in folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
}

/// Snapshot, change the index, restore: the next launch's index has the snapshot's rows, the
/// one it replaced is kept aside, and the index before the restore is a snapshot too.
@Test func aRestoreRoundTrip() throws {
    let library = try SnapshotTestLibrary()
    let yesterday = Date().addingTimeInterval(-86_400)
    let snapshot = try writeSnapshot(
        of: library.index(), keeping: library.paths, into: library.snapshotFolder, on: yesterday)
    let before = try counts(library.index())
    try library.index().recordPlay(library.played, at: SnapshotTestLibrary.playedAt + 60)
    #expect(try counts(library.index()).plays == before.plays + 1)

    try prepareRestore(
        of: snapshot, paths: library.paths, snapshotFolder: library.snapshotFolder,
        now: Date())
    // Nothing is replaced until the next launch.
    #expect(try counts(library.index()).plays == before.plays + 1)
    let saved = try snapshots(in: library.snapshotFolder)
    #expect(saved.map(\.isBeforeRestore) == [true, false])
    #expect(saved[1].name == SnapshotName(of: yesterday))

    #expect(
        try applyPendingRestore(paths: library.paths)
            == .applied(snapshot.lastPathComponent))
    #expect(try counts(library.index()) == before)
    let left = try names(in: library.directory)
    #expect(left.contains { $0.hasPrefix("library.sqlite.replaced-") })
    #expect(!left.contains("restore.pending"))
    #expect(!left.contains { $0.hasPrefix("library.sqlite.restoring") })
    // A second launch has nothing to restore.
    #expect(try applyPendingRestore(paths: library.paths) == .none)

    // The index before the restore is a snapshot, with the play the restore undid.
    let unpacked = library.directory.appendingPathComponent("before-restore.sqlite")
    try GzipFile.decompress(saved[0].url, to: unpacked)
    #expect(try counts(LibraryIndex(at: unpacked)).plays == before.plays + 1)
}

@Test func aDamagedSnapshotIsRefusedBeforeAnythingIsReplaced() throws {
    let library = try SnapshotTestLibrary()
    let snapshot = try writeSnapshot(
        of: library.index(), keeping: library.paths, into: library.snapshotFolder,
        on: Date().addingTimeInterval(-86_400))
    let whole = try Data(contentsOf: snapshot)
    try whole.prefix(whole.count / 2).write(to: snapshot)
    let before = try names(in: library.directory)
    let snapshotsBefore = try names(in: library.snapshotFolder)
    #expect(throws: SnapshotError.self) {
        try prepareRestore(
            of: snapshot, paths: library.paths,
            snapshotFolder: library.snapshotFolder, now: Date())
    }
    #expect(try names(in: library.directory) == before)
    #expect(try names(in: library.snapshotFolder) == snapshotsBefore)
    #expect(try applyPendingRestore(paths: library.paths) == .none)
}

@Test func aGzipOfSomethingElseIsRefusedAsDamaged() throws {
    let library = try SnapshotTestLibrary()
    let plain = library.directory.appendingPathComponent("notes.txt")
    try Data(String(repeating: "not a database ", count: 400).utf8).write(to: plain)
    let packed = library.snapshotFolder.appendingPathComponent(
        SnapshotName(of: Date().addingTimeInterval(-86_400)).fileName)
    try FileManager.default.createDirectory(
        at: library.snapshotFolder, withIntermediateDirectories: true)
    try GzipFile.compress(plain, to: packed)
    #expect {
        try prepareRestore(
            of: packed, paths: library.paths, snapshotFolder: library.snapshotFolder,
            now: Date())
    } throws: { error in
        if case SnapshotError.damaged = error { return true }
        return false
    }
    #expect(try applyPendingRestore(paths: library.paths) == .none)
}

/// Restoring the day's own snapshot: the index before the restore takes a name of its own, so
/// the day's snapshot is still the one restored, and Settings lists both.
@Test func aRestoreTheSameDayKeepsTheDaysSnapshot() throws {
    let library = try SnapshotTestLibrary()
    let now = Date()
    let today = try writeSnapshot(
        of: library.index(), keeping: library.paths, into: library.snapshotFolder, on: now)
    let before = try counts(library.index())
    try library.index().recordPlay(library.played, at: SnapshotTestLibrary.playedAt + 60)
    try prepareRestore(
        of: today, paths: library.paths, snapshotFolder: library.snapshotFolder,
        now: now.addingTimeInterval(1))
    let saved = try snapshots(in: library.snapshotFolder)
    #expect(saved.count == 2)
    #expect(saved.map(\.day) == [SnapshotName(of: now).day, SnapshotName(of: now).day])
    let daily = try #require(saved.first { !$0.isBeforeRestore })
    #expect(daily.url.lastPathComponent == today.lastPathComponent)
    let unpacked = library.directory.appendingPathComponent("daily.sqlite")
    try GzipFile.decompress(today, to: unpacked)
    #expect(try counts(LibraryIndex(at: unpacked)) == before)
    _ = try applyPendingRestore(paths: library.paths)
    #expect(try counts(library.index()) == before)
}

@Test func onlyTheNewestSnapshotsBeforeARestoreAreKept() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let names = (0..<5).map {
        SnapshotName(of: start.addingTimeInterval(Double($0) * 61), beforeRestore: true)
    }
    let daily = SnapshotName(of: start)
    #expect(
        Set(SnapshotRotation.expired(names + [daily])) == Set(names.prefix(2)))
}

/// A library with a restore prepared from yesterday's snapshot, after a play the restore takes
/// away, and the counts before that play.
private func preparedRestore() throws -> (SnapshotTestLibrary, (tracks: Int, plays: Int)) {
    let library = try SnapshotTestLibrary()
    let snapshot = try writeSnapshot(
        of: library.index(), keeping: library.paths, into: library.snapshotFolder,
        on: Date().addingTimeInterval(-86_400))
    let before = try counts(library.index())
    try library.index().recordPlay(library.played, at: SnapshotTestLibrary.playedAt + 60)
    try prepareRestore(
        of: snapshot, paths: library.paths, snapshotFolder: library.snapshotFolder,
        now: Date())
    return (library, before)
}

private struct Refused: Error {}

@Test func aRestoreWaitsWhileAnotherCopyHasTheIndexOpen() throws {
    let (library, before) = try preparedRestore()
    var other: IndexInUse? = try IndexInUse(databaseURL: library.databaseURL)
    #expect(
        try applyPendingRestore(paths: library.paths)
            == .waiting("another copy of the app has the library open"))
    #expect(try counts(library.index()).plays == before.plays + 1)
    other = nil
    _ = other
    #expect(try applyPendingRestore(paths: library.paths) != .none)
    #expect(try counts(library.index()) == before)
}

/// The move into place fails: the index goes back, and the restore waits for the next launch.
@Test func aFailedSwapPutsTheIndexBack() throws {
    let (library, before) = try preparedRestore()
    var moves = 0
    #expect(throws: Refused.self) {
        try applyPendingRestore(paths: library.paths) { from, to in
            moves += 1
            if moves == 1 { throw Refused() }
            try LibraryIndex.move(from, to: to)
        }
    }
    #expect(try counts(library.index()).plays == before.plays + 1)
    let left = try names(in: library.directory)
    #expect(!left.contains { $0.hasPrefix("library.sqlite.replaced-") })
    #expect(left.contains("restore.pending"))
    #expect(try applyPendingRestore(paths: library.paths) != .none)
    #expect(try counts(library.index()) == before)
}

/// When the index can't go back either, the error says where it is, for the app to quit on.
@Test func anIndexThatCantGoBackSaysWhereItIs() throws {
    let (library, _) = try preparedRestore()
    #expect {
        try applyPendingRestore(paths: library.paths) { _, _ in throw Refused() }
    } throws: { error in
        guard case SnapshotError.indexNotPutBack(let path, _) = error else { return false }
        return path.contains("library.sqlite.replaced-")
    }
}

/// A launch stopped between moving the index aside and the swap: the next one swaps, and
/// pruning keeps the index moved aside, the newest, over older ones.
@Test func aSwapStoppedPartwayFinishesAndKeepsTheMovedIndex() throws {
    let (library, before) = try preparedRestore()
    for stamp in ["2000-01-01", "2000-01-02", "2000-01-03"] {
        try Data("old".utf8).write(
            to: library.directory.appendingPathComponent("library.sqlite.replaced-\(stamp)"))
    }
    let moved = try LibraryIndex.moveAside(library.databaseURL, reason: "replaced", pruning: false)
    #expect(
        try applyPendingRestore(paths: library.paths) != .none)
    #expect(try counts(library.index()) == before)
    let replaced = try names(in: library.directory).filter {
        $0.hasPrefix("library.sqlite.replaced-") && !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm")
    }
    #expect(replaced.count == LibraryIndex.keptUnreadableFiles)
    #expect(replaced.contains(moved.lastPathComponent))
    #expect(!replaced.contains("library.sqlite.replaced-2000-01-01"))
    #expect(try counts(LibraryIndex(at: moved)).plays == before.plays + 1)
}

/// A launch stopped after the swap, before deleting the marker: the restore was made.
@Test func aMarkerLeftAfterTheSwapReadsAsApplied() throws {
    let (library, before) = try preparedRestore()
    let restoring = URL(fileURLWithPath: library.databaseURL.path + ".restoring")
    try LibraryIndex.move(library.databaseURL, to: library.directory.appendingPathComponent("old"))
    try LibraryIndex.move(restoring, to: library.databaseURL)
    guard case .applied = try applyPendingRestore(paths: library.paths) else {
        Issue.record("not applied")
        return
    }
    #expect(!(try names(in: library.directory).contains("restore.pending")))
    #expect(try counts(library.index()) == before)
}

@Test func aMarkerWithNothingToRestoreSaysSoOnce() throws {
    let (library, _) = try preparedRestore()
    try FileManager.default.removeItem(atPath: library.databaseURL.path + ".restoring")
    try LibraryIndex.move(library.databaseURL, to: library.directory.appendingPathComponent("old"))
    #expect {
        try applyPendingRestore(paths: library.paths)
    } throws: { error in
        guard case SnapshotError.restoreMissing = error else { return false }
        return true
    }
    #expect(try applyPendingRestore(paths: library.paths) == .none)
}

/// The index's snapshot before the restore fails: the unpacked file goes too, and nothing waits.
@Test func aFailedSnapshotBeforeARestoreLeavesNothingPending() throws {
    let library = try SnapshotTestLibrary()
    let snapshot = try writeSnapshot(
        of: library.index(), keeping: library.paths, into: library.snapshotFolder,
        on: Date().addingTimeInterval(-86_400))
    // A file where the folder for the snapshot before the restore should be.
    let blocked = library.directory.appendingPathComponent("Blocked")
    try Data().write(to: blocked)
    #expect(throws: (any Error).self) {
        try prepareRestore(
            of: snapshot, paths: library.paths, snapshotFolder: blocked, now: Date())
    }
    let left = try names(in: library.directory)
    #expect(!left.contains { $0.hasPrefix("library.sqlite.restoring") })
    #expect(!left.contains("restore.pending"))
}

/// A second Restore… that fails takes the first's marker with it, so the next launch doesn't
/// say a restore was made.
@Test func aFailedSecondRestoreLeavesNoMarkerBehind() throws {
    let (library, before) = try preparedRestore()
    let damaged = library.snapshotFolder.appendingPathComponent(
        SnapshotName(of: Date().addingTimeInterval(-2 * 86_400)).fileName)
    try Data("not gzip".utf8).write(to: damaged)
    #expect(throws: SnapshotError.self) {
        try prepareRestore(
            of: damaged, paths: library.paths,
            snapshotFolder: library.snapshotFolder, now: Date())
    }
    #expect(!(try names(in: library.directory).contains("restore.pending")))
    #expect(try applyPendingRestore(paths: library.paths) == .none)
    #expect(try counts(library.index()).plays == before.plays + 1)
}
