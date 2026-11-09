import Foundation
import Testing

@testable import Snapshot

@Test func theDailySnapshotIsWrittenOnceADay() throws {
    let library = try SnapshotTestLibrary()
    let scheduler = SnapshotScheduler(paths: library.paths)
    let morning = try #require(
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9)))
    #expect(scheduler.writeIfDue(into: library.snapshotFolder, now: morning))
    #expect(
        !scheduler.writeIfDue(into: library.snapshotFolder, now: morning.addingTimeInterval(60)))
    #expect(try snapshots(in: library.snapshotFolder).count == 1)
    #expect(
        scheduler.writeIfDue(into: library.snapshotFolder, now: morning.addingTimeInterval(86_400)))
    #expect(try snapshots(in: library.snapshotFolder).count == 2)
    #expect(scheduler.lastProblem == nil)
}

@Test func aSecondAskWhileOneWaitsQueuesNothing() throws {
    let library = try SnapshotTestLibrary()
    let scheduler = SnapshotScheduler(paths: library.paths)
    let job = try #require(scheduler.dailyJob(into: library.snapshotFolder))
    #expect(scheduler.dailyJob(into: library.snapshotFolder) == nil)
    job()
    #expect(try snapshots(in: library.snapshotFolder).count == 1)
    // Once it has run, the next ask makes another.
    #expect(scheduler.dailyJob(into: library.snapshotFolder) != nil)
}

@Test func aFailedSnapshotSaysWhyUntilOneIsWritten() throws {
    let library = try SnapshotTestLibrary()
    let scheduler = SnapshotScheduler(paths: library.paths)
    // A file where the folder should be.
    try Data().write(to: library.snapshotFolder)
    #expect(!scheduler.write(into: library.snapshotFolder, now: Date()))
    let failure = try #require(scheduler.lastProblem)
    #expect(failure.contains("Backups"))
    try FileManager.default.removeItem(at: library.snapshotFolder)
    #expect(scheduler.write(into: library.snapshotFolder, now: Date()))
    #expect(scheduler.lastProblem == nil)
}

/// Older snapshots that can't be deleted don't make the one written a failure.
@Test func aRotationThatFailsStillCountsTheSnapshotWritten() throws {
    let library = try SnapshotTestLibrary()
    let folder = library.snapshotFolder
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let stuck = folder.appendingPathComponent("library-2000-01-01.sqlite.gz")
    try Data("old".utf8).write(to: stuck)
    for day in 2...8 {
        try Data("old".utf8).write(
            to: folder.appendingPathComponent("library-2000-02-0\(day).sqlite.gz"))
    }
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: stuck.path)
    defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: stuck.path) }
    let scheduler = SnapshotScheduler(paths: library.paths)
    #expect(scheduler.write(into: folder, now: Date()))
    #expect(try snapshots(in: folder).contains { $0.day == SnapshotName(of: Date()).day })
    let problem = try #require(scheduler.lastProblem)
    #expect(problem.hasPrefix("The last snapshot was written, but older ones couldn't be deleted"))
}

/// An entry named as a snapshot whose size can't be read is left out, not the whole list.
@Test func anUnreadableEntryIsLeftOutOfTheList() throws {
    let library = try SnapshotTestLibrary()
    let folder = library.snapshotFolder
    try writeSnapshot(of: library.index(), keeping: library.paths, into: folder, on: Date())
    // A folder has no file size to read.
    try FileManager.default.createDirectory(
        at: folder.appendingPathComponent("library-2000-01-01.sqlite.gz"),
        withIntermediateDirectories: false)
    #expect(try snapshots(in: folder).map(\.day) == [SnapshotName(of: Date()).day])
}
