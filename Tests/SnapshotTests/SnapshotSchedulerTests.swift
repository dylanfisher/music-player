import Foundation
import Testing

@testable import Snapshot

@Test func theDailySnapshotIsWrittenOnceADay() throws {
    let library = try SnapshotTestLibrary()
    let scheduler = SnapshotScheduler(databaseURL: library.databaseURL)
    let morning = try #require(
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9)))
    #expect(scheduler.writeIfDue(into: library.snapshotFolder, now: morning))
    #expect(
        !scheduler.writeIfDue(into: library.snapshotFolder, now: morning.addingTimeInterval(60)))
    #expect(try snapshots(in: library.snapshotFolder).count == 1)
    #expect(
        scheduler.writeIfDue(into: library.snapshotFolder, now: morning.addingTimeInterval(86_400)))
    #expect(try snapshots(in: library.snapshotFolder).count == 2)
    #expect(scheduler.lastFailure == nil)
}

@Test func aSecondAskWhileOneWaitsQueuesNothing() throws {
    let library = try SnapshotTestLibrary()
    let scheduler = SnapshotScheduler(databaseURL: library.databaseURL)
    let job = try #require(scheduler.dailyJob(into: library.snapshotFolder))
    #expect(scheduler.dailyJob(into: library.snapshotFolder) == nil)
    job()
    #expect(try snapshots(in: library.snapshotFolder).count == 1)
    // Once it has run, the next ask makes another.
    #expect(scheduler.dailyJob(into: library.snapshotFolder) != nil)
}

@Test func aFailedSnapshotSaysWhyUntilOneIsWritten() throws {
    let library = try SnapshotTestLibrary()
    let scheduler = SnapshotScheduler(databaseURL: library.databaseURL)
    // A file where the folder should be.
    try Data().write(to: library.snapshotFolder)
    #expect(!scheduler.write(into: library.snapshotFolder, now: Date()))
    let failure = try #require(scheduler.lastFailure)
    #expect(failure.contains("Backups"))
    try FileManager.default.removeItem(at: library.snapshotFolder)
    #expect(scheduler.write(into: library.snapshotFolder, now: Date()))
    #expect(scheduler.lastFailure == nil)
}
