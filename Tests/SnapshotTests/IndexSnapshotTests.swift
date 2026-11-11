import Foundation
import Testing

@testable import Library
@testable import Snapshot

/// A calendar in UTC, so the days don't move with the machine's time zone.
private let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}()

/// Noon UTC on `day` days after 2026-01-01.
private func noon(_ day: Int) -> Date {
    utcCalendar.date(
        from: DateComponents(year: 2026, month: 1, day: 1 + day, hour: 12)) ?? .distantPast
}

@Test func aSnapshotIsNamedByItsLocalDay() throws {
    let name = SnapshotName(of: noon(304), calendar: utcCalendar)
    #expect(name.fileName == "library-2026-11-01.sqlite.gz")
    #expect(SnapshotName(fileName: name.fileName) == name)
    let restore = SnapshotName(of: noon(304), beforeRestore: true, calendar: utcCalendar)
    #expect(restore.fileName == "library-2026-11-01-before-restore-120000.sqlite.gz")
    #expect(SnapshotName(fileName: restore.fileName) == restore)
    #expect(restore != name && name < restore)
    #expect(SnapshotName(fileName: "library-2026-11-01-before-restore-250000.sqlite.gz") == nil)
    // A day starts at local midnight: 23:30 UTC is the next day in Tokyo.
    var tokyo = utcCalendar
    tokyo.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
    let late = noon(304).addingTimeInterval(11.5 * 3600)
    #expect(SnapshotName(of: late, calendar: utcCalendar).day == "2026-11-01")
    #expect(SnapshotName(of: late, calendar: tokyo).day == "2026-11-02")
    for other in [
        "library-2026-1-5.sqlite.gz", "library-2026-13-01.sqlite.gz", "notes.txt",
        "library-2026-11-01.sqlite.gz.partial", "library-2026-11-01.sqlite",
        "library.sqlite.gz",
    ] {
        #expect(SnapshotName(fileName: other) == nil, "\(other)")
    }
    #expect(SnapshotName.isPartial(name.partialFileName("a")))
    #expect(SnapshotName.isPartial(name.copyFileName("a")))
    #expect(name.partialFileName("a") != name.partialFileName("b"))
    #expect(SnapshotName(fileName: name.partialFileName("a")) == nil)
    #expect(!SnapshotName.isPartial(name.fileName))
    #expect(!SnapshotName.isPartial("notes.partial"))
    #expect(!SnapshotName.isPartial(".notes.partial"))
}

/// A snapshot a day for 60 days, rotated after each, as the scheduler does: the last 7 days
/// stay, and the newest of each of the 4 weeks before them, which is its Sunday.
@Test func rotationKeepsAWeekOfDaysAndFourWeeksBeforeThem() throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("rotation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let other = folder.appendingPathComponent("notes.txt", isDirectory: false)
    try Data("mine".utf8).write(to: other)
    let library = try SnapshotTestLibrary()
    let index = try library.index()
    for day in 0..<60 {
        try writeSnapshot(
            of: index, keeping: library.paths, into: folder, on: noon(day), calendar: utcCalendar)
    }
    let kept = try snapshots(in: folder).map(\.day)
    // Day 59 is Sunday 2026-03-01; its week started on Monday 02-23.
    #expect(
        kept == [
            "2026-03-01", "2026-02-28", "2026-02-27", "2026-02-26", "2026-02-25", "2026-02-24",
            "2026-02-23", "2026-02-22", "2026-02-15", "2026-02-08", "2026-02-01",
        ])
    // The state and config copies go with their day's snapshot.
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    #expect(
        Set(names)
            == Set(
                kept.flatMap {
                    ["library-\($0).sqlite.gz", "state-\($0).json", "config-\($0).json"]
                }
                    + ["notes.txt"]))
    #expect(try String(contentsOf: other, encoding: .utf8) == "mine")
}

@Test func rotationKeepsEverythingUntilThereAreMoreThanSeven() {
    let names = (0..<7).map { SnapshotName(of: noon($0 * 40), calendar: utcCalendar) }
    #expect(SnapshotRotation.expired(names, calendar: utcCalendar).isEmpty)
    // Days 0, 40, ... 280: the oldest is more than four weeks before the next, so it goes.
    let eight = names + [SnapshotName(of: noon(280), calendar: utcCalendar)]
    #expect(SnapshotRotation.expired(eight, calendar: utcCalendar) == [names[0]])
}

@Test func aSnapshotUnpacksToTheSameLibrary() throws {
    let library = try SnapshotTestLibrary()
    let before = try counts(library.index())
    #expect(before.tracks > 0 && before.plays == 1)
    let snapshot = try writeSnapshot(
        of: library.index(), keeping: library.paths, into: library.snapshotFolder, on: noon(304))
    let name = SnapshotName(of: noon(304))
    #expect(snapshot.lastPathComponent == name.fileName)
    // Only the snapshot and its copies are left in the folder.
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: library.snapshotFolder.path).sorted()
            == [name.fileName(of: .config), name.fileName, name.fileName(of: .state)])
    let unpacked = library.directory.appendingPathComponent("unpacked.sqlite")
    try GzipFile.decompress(snapshot, to: unpacked)
    let after = try counts(LibraryIndex(at: unpacked))
    #expect(after == before)
    // The index itself is as it was.
    #expect(try counts(library.index()) == before)
}

@Test func aSecondSnapshotTheSameDayReplacesTheFirst() throws {
    let library = try SnapshotTestLibrary()
    let first = try writeSnapshot(
        of: library.index(), keeping: library.paths, into: library.snapshotFolder, on: noon(1))
    try library.index().recordPlay(library.played, at: SnapshotTestLibrary.playedAt + 60)
    let second = try writeSnapshot(
        of: library.index(), keeping: library.paths, into: library.snapshotFolder, on: noon(1))
    #expect(first == second)
    #expect(try snapshots(in: library.snapshotFolder).count == 1)
    let unpacked = library.directory.appendingPathComponent("unpacked.sqlite")
    try GzipFile.decompress(second, to: unpacked)
    #expect(try counts(LibraryIndex(at: unpacked)).plays == 2)
}

@Test func aGzipCutShortOrWithMoreAfterItIsRefused() throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("gzip-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let plain = folder.appendingPathComponent("plain")
    // More than a chunk, so the stream spans reads.
    let bytes = Data((0..<(GzipFile.chunkBytes * 2 + 17)).map { UInt8(truncatingIfNeeded: $0 * 7) })
    try bytes.write(to: plain)
    let packed = folder.appendingPathComponent("plain.gz")
    try GzipFile.compress(plain, to: packed)
    let back = folder.appendingPathComponent("back")
    try GzipFile.decompress(packed, to: back)
    #expect(try Data(contentsOf: back) == bytes)

    let whole = try Data(contentsOf: packed)
    let short = folder.appendingPathComponent("short.gz")
    try whole.prefix(whole.count - 4).write(to: short)
    #expect(throws: SnapshotError.gzip("short.gz", "it ends early")) {
        try GzipFile.decompress(short, to: folder.appendingPathComponent("short"))
    }
    let longer = folder.appendingPathComponent("longer.gz")
    try (whole + Data("x".utf8)).write(to: longer)
    #expect(throws: SnapshotError.gzip("longer.gz", "it has data after its end")) {
        try GzipFile.decompress(longer, to: folder.appendingPathComponent("longer"))
    }
    var flipped = whole
    flipped[whole.count / 2] ^= 0xFF
    let damaged = folder.appendingPathComponent("damaged.gz")
    try flipped.write(to: damaged)
    #expect(throws: SnapshotError.self) {
        try GzipFile.decompress(damaged, to: folder.appendingPathComponent("damaged"))
    }
}

/// A write's leftovers older than the cutoff go; a newer one, maybe another copy's write under
/// way, and every other file stay.
@Test func onlyOldLeftoversOfAWriteAreDeleted() throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("partials-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let name = SnapshotName(of: noon(1), calendar: utcCalendar)
    let old = folder.appendingPathComponent(name.copyFileName("old"))
    let new = folder.appendingPathComponent(name.partialFileName("new"))
    let mine = folder.appendingPathComponent(".notes.partial")
    let snapshot = folder.appendingPathComponent(name.fileName)
    for url in [old, new, mine, snapshot] { try Data("x".utf8).write(to: url) }
    let hourAgo = Date().addingTimeInterval(-3600)
    try FileManager.default.setAttributes(
        [.modificationDate: hourAgo.addingTimeInterval(-60)], ofItemAtPath: old.path)
    try FileManager.default.setAttributes(
        [.modificationDate: hourAgo.addingTimeInterval(-60)], ofItemAtPath: mine.path)
    try removePartials(in: folder, olderThan: hourAgo)
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            == [new, mine, snapshot].map(\.lastPathComponent).sorted())
}

/// Writes from several queues at once, as the daily job, Back Up Now and a restore can be,
/// each finish whole: one snapshot of the day that unpacks to the library, and no leftovers.
@Test func writesAtOnceTakeTurns() throws {
    let library = try SnapshotTestLibrary()
    let before = try counts(library.index())
    let folder = library.snapshotFolder
    let path = library.databaseURL
    let paths = library.paths
    let failures = Failures()
    // Each opens its index first, so the writes themselves start together.
    let indexes = try (0..<8).map { _ in try LibraryIndex(at: path) }
    let shared = UnsafeIndexes(indexes)
    DispatchQueue.concurrentPerform(iterations: indexes.count) { position in
        do {
            try writeSnapshot(
                of: shared.indexes[position], keeping: paths, into: folder, on: noon(304))
        } catch {
            failures.add("\(error)")
        }
    }
    #expect(failures.all.isEmpty)
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    let name = SnapshotName(of: noon(304))
    #expect(
        names.sorted() == [name.fileName(of: .config), name.fileName, name.fileName(of: .state)])
    let unpacked = library.directory.appendingPathComponent("unpacked.sqlite")
    try GzipFile.decompress(folder.appendingPathComponent(name.fileName), to: unpacked)
    #expect(try counts(LibraryIndex(at: unpacked)) == before)
}

/// Connections handed to one thread each, which `LibraryIndex` allows.
private final class UnsafeIndexes: @unchecked Sendable {
    let indexes: [LibraryIndex]
    init(_ indexes: [LibraryIndex]) { self.indexes = indexes }
}

private final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private var found: [String] = []

    func add(_ failure: String) { lock.withLock { found.append(failure) } }
    var all: [String] { lock.withLock { found } }
}

/// A folder on a network volume, such as a watched share where it's mounted, is refused.
@Test func aSnapshotFolderOnANetworkVolumeIsRefused() throws {
    let folder = URL(fileURLWithPath: "/Volumes/music/Backups", isDirectory: true)
    #expect(throws: SnapshotError.networkFolder(folder.path)) {
        try requireLocal(folder, isLocal: false)
    }
    #expect(throws: SnapshotError.networkFolder(folder.path)) {
        try requireLocal(folder, isLocal: nil)
    }
    try requireLocal(FileManager.default.temporaryDirectory, isLocal: true)
}

/// A leftover another copy deletes between the listing and the read of its date is gone, not
/// a failed write.
@Test func aLeftoverThatVanishesIsTakenAsGone() throws {
    let gone = FileManager.default.temporaryDirectory
        .appendingPathComponent(".library-2026-11-01-\(UUID().uuidString).sqlite.partial")
    #expect(try modificationDate(gone) == nil)
    try Data("x".utf8).write(to: gone)
    #expect(try modificationDate(gone) != nil)
}

/// A name that would climb out of the snapshot folder, or name a file in another, is no
/// snapshot's, so a restore never reads it or a copy beside it (ADR 0025, row 75).
@Test func aSnapshotNameHasNoPathInIt() {
    #expect(SnapshotName(fileName: "library-2026-11-01.sqlite.gz") != nil)
    for name in [
        "library-../../x.sqlite.gz", "library-2026-11-01/../../x.sqlite.gz",
        "../library-2026-11-01.sqlite.gz", "library-2026-11-01-before-restore-../x.sqlite.gz",
        "library-/etc/passwd.sqlite.gz", "library-2026-11-01-before-restore-12/345.sqlite.gz",
        "/library-2026-11-01.sqlite.gz",
    ] {
        #expect(SnapshotName(fileName: name) == nil, "\(name)")
    }
}
