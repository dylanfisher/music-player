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
        of: library.index(), into: library.snapshotFolder, on: yesterday)
    let before = try counts(library.index())
    try library.index().recordPlay(library.played, at: SnapshotTestLibrary.playedAt + 60)
    #expect(try counts(library.index()).plays == before.plays + 1)

    try prepareRestore(
        of: snapshot, databaseURL: library.databaseURL, snapshotFolder: library.snapshotFolder,
        now: Date())
    // Nothing is replaced until the next launch.
    #expect(try counts(library.index()).plays == before.plays + 1)
    let saved = try snapshots(in: library.snapshotFolder)
    #expect(saved.map(\.isBeforeRestore) == [true, false])
    #expect(saved[1].name == SnapshotName(of: yesterday))

    #expect(try applyPendingRestore(databaseURL: library.databaseURL) == snapshot.lastPathComponent)
    #expect(try counts(library.index()) == before)
    let left = try names(in: library.directory)
    #expect(left.contains { $0.hasPrefix("library.sqlite.replaced-") })
    #expect(!left.contains("restore.pending"))
    #expect(!left.contains { $0.hasPrefix("library.sqlite.restoring") })
    // A second launch has nothing to restore.
    #expect(try applyPendingRestore(databaseURL: library.databaseURL) == nil)

    // The index before the restore is a snapshot, with the play the restore undid.
    let unpacked = library.directory.appendingPathComponent("before-restore.sqlite")
    try GzipFile.decompress(saved[0].url, to: unpacked)
    #expect(try counts(LibraryIndex(at: unpacked)).plays == before.plays + 1)
}

@Test func aDamagedSnapshotIsRefusedBeforeAnythingIsReplaced() throws {
    let library = try SnapshotTestLibrary()
    let snapshot = try writeSnapshot(
        of: library.index(), into: library.snapshotFolder, on: Date().addingTimeInterval(-86_400))
    let whole = try Data(contentsOf: snapshot)
    try whole.prefix(whole.count / 2).write(to: snapshot)
    let before = try names(in: library.directory)
    let snapshotsBefore = try names(in: library.snapshotFolder)
    #expect(throws: SnapshotError.self) {
        try prepareRestore(
            of: snapshot, databaseURL: library.databaseURL,
            snapshotFolder: library.snapshotFolder, now: Date())
    }
    #expect(try names(in: library.directory) == before)
    #expect(try names(in: library.snapshotFolder) == snapshotsBefore)
    #expect(try applyPendingRestore(databaseURL: library.databaseURL) == nil)
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
            of: packed, databaseURL: library.databaseURL, snapshotFolder: library.snapshotFolder,
            now: Date())
    } throws: { error in
        if case SnapshotError.damaged = error { return true }
        return false
    }
    #expect(try applyPendingRestore(databaseURL: library.databaseURL) == nil)
}

/// Restoring the day's own snapshot: the index before the restore takes a name of its own, so
/// the day's snapshot is still the one restored, and Settings lists both.
@Test func aRestoreTheSameDayKeepsTheDaysSnapshot() throws {
    let library = try SnapshotTestLibrary()
    let now = Date()
    let today = try writeSnapshot(of: library.index(), into: library.snapshotFolder, on: now)
    let before = try counts(library.index())
    try library.index().recordPlay(library.played, at: SnapshotTestLibrary.playedAt + 60)
    try prepareRestore(
        of: today, databaseURL: library.databaseURL, snapshotFolder: library.snapshotFolder,
        now: now.addingTimeInterval(1))
    let saved = try snapshots(in: library.snapshotFolder)
    #expect(saved.count == 2)
    #expect(saved.map(\.day) == [SnapshotName(of: now).day, SnapshotName(of: now).day])
    let daily = try #require(saved.first { !$0.isBeforeRestore })
    #expect(daily.url.lastPathComponent == today.lastPathComponent)
    let unpacked = library.directory.appendingPathComponent("daily.sqlite")
    try GzipFile.decompress(today, to: unpacked)
    #expect(try counts(LibraryIndex(at: unpacked)) == before)
    _ = try applyPendingRestore(databaseURL: library.databaseURL)
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
