import Foundation
import Metadata
import Testing

@testable import Library

private let stamp = FileStamp(sizeBytes: 12_345, modifiedSeconds: 1_700_000_000.25)

private let measured = FileMeasures(
    formatID: "flac", sampleRateHz: 96_000, storedBits: 24, channels: 2, isFloat: false,
    durationSeconds: 300.5, cutoffHz: 22_050, cutoffSteepnessDBPerKHz: 150,
    effectiveBits: 16, identicalChannels: false, peakDBFS: -0.1, truePeakDBTP: 0.4,
    clippedRuns: 12, dynamicRange: 7)

/// Nil and absent measures come back as nil, not as zeros.
private let silent = FileMeasures(
    formatID: "aac ", sampleRateHz: 44_100, storedBits: nil, channels: 1, isFloat: true,
    durationSeconds: 1, cutoffHz: nil, cutoffSteepnessDBPerKHz: nil, effectiveBits: nil,
    identicalChannels: nil, peakDBFS: nil, truePeakDBTP: nil, clippedRuns: 0, dynamicRange: nil)

/// Making the cache opens nothing: the app makes it on the main thread at launch, while a scan
/// may hold the index, so the connection opens on the cache's first use, off that thread.
@Test func theCacheOpensItsConnectionOnFirstUse() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("measures-cache-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = libraryFileURL(in: directory)
    let cache = MeasuresCache(databaseURL: databaseURL)
    #expect(!FileManager.default.fileExists(atPath: databaseURL.path))
    #expect(try await cache.analysisFiles().total == 0)
    #expect(FileManager.default.fileExists(atPath: databaseURL.path))
}

@Test func measuresComeBackForTheSameFile() async throws {
    let library = try TestLibrary()
    let cache = MeasuresCache(databaseURL: library.databaseURL)
    try await cache.store(measured, path: "/a.flac", stamp: stamp)
    try await cache.store(silent, path: "/b.m4a", stamp: stamp)
    #expect(try await cache.measures(path: "/a.flac", stamp: stamp) == measured)
    #expect(try await cache.measures(path: "/b.m4a", stamp: stamp) == silent)
    #expect(try await cache.measures(path: "/c.flac", stamp: stamp) == nil)
}

@Test func measuresOfAChangedFileAreIgnoredAndReplaced() async throws {
    let library = try TestLibrary()
    let cache = MeasuresCache(databaseURL: library.databaseURL)
    try await cache.store(measured, path: "/a.flac", stamp: stamp)
    let grown = FileStamp(sizeBytes: stamp.sizeBytes + 1, modifiedSeconds: stamp.modifiedSeconds)
    let touched = FileStamp(sizeBytes: stamp.sizeBytes, modifiedSeconds: stamp.modifiedSeconds + 1)
    #expect(try await cache.measures(path: "/a.flac", stamp: grown) == nil)
    #expect(try await cache.measures(path: "/a.flac", stamp: touched) == nil)
    try await cache.store(silent, path: "/a.flac", stamp: touched)
    #expect(try await cache.measures(path: "/a.flac", stamp: touched) == silent)
    #expect(try await cache.measures(path: "/a.flac", stamp: stamp) == nil)
}

@Test func theFilesToAnalyzeAreTheTracksWithoutMeasuresOfTheFileAsIndexed() async throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let rows = try index.rows(ids: try index.trackIDs(sortedBy: .path))
    let analyzable = rows.filter { !["dsf", "dff"].contains($0.fileType.lowercased()) }
    #expect(analyzable.count < rows.count)
    let cache = MeasuresCache(databaseURL: library.databaseURL)
    let before = try await cache.analysisFiles().pending
    #expect(before.map(\.path) == analyzable.map(\.path).sorted())
    #expect(
        before.map(\.stamp)
            == analyzable.sorted { $0.path < $1.path }.map {
                FileStamp(sizeBytes: $0.sizeBytes, modifiedSeconds: $0.modifiedSeconds)
            })

    // One analyzed as indexed, one from before its file changed.
    try await cache.store(measured, path: before[0].path, stamp: before[0].stamp)
    var older = before[1].stamp
    older.sizeBytes += 1
    try await cache.store(measured, path: before[1].path, stamp: older)
    #expect(try await cache.analysisFiles().pending.map(\.path) == before.dropFirst().map(\.path))
}

@Test func measuresRebuiltOnTheirOwnKeepTheStatsAndReportNothing() throws {
    let library = try TestLibrary()
    let index = try library.index()
    try index.recordPlay("/x.flac", at: 100)
    try index.storeMeasures(measured, path: "/x.flac", stamp: stamp)
    try index.database.execute("UPDATE schema_identity SET sql = 'older' WHERE part = 'measures'")

    let rebuilt = try library.index()
    #expect(try rebuilt.measures(path: "/x.flac", stamp: stamp) == nil)
    #expect(try rebuilt.database.prepare("SELECT count(*) FROM plays").map { try $0.int(0) } == [1])
    #expect(try rebuilt.discards().isEmpty)
}

@Test func anIndexRebuildKeepsTheMeasures() throws {
    let library = try TestLibrary()
    let index = try library.index()
    try index.storeMeasures(measured, path: "/x.flac", stamp: stamp)
    try index.database.execute("UPDATE schema_identity SET sql = 'older' WHERE part = 'index'")

    #expect(try library.index().measures(path: "/x.flac", stamp: stamp) == measured)
}

/// A run again counts the files measured before it as not done, keeps their measures until
/// new ones are stored, and carries on from where it got to on a new connection, as after a
/// relaunch.
@Test func aRunAgainListsTheFilesMeasuredBeforeItAndCarriesOnAfterARelaunch() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let files = try index.analysisFiles().pending
    let earlier = Date(timeIntervalSince1970: 1_000)
    for file in files {
        try index.storeMeasures(measured, path: file.path, stamp: file.stamp, now: earlier)
    }
    try index.beginAnalysisRun(again: false)
    try index.finishAnalysisRun()
    var done = try index.analysisFiles()
    #expect(done.pending.isEmpty && done.done == files.count && !done.unfinished)

    try index.beginAnalysisRun(again: true, now: Date(timeIntervalSince1970: 2_000))
    var again = try index.analysisFiles()
    #expect(again.pending.map(\.path) == files.map(\.path))
    #expect(again.done == 0 && again.unfinished)
    #expect(try index.measures(path: files[0].path, stamp: files[0].stamp) == measured)
    try index.storeMeasures(
        silent, path: files[0].path, stamp: files[0].stamp,
        now: Date(timeIntervalSince1970: 3_000))

    let relaunched = try library.index()
    again = try relaunched.analysisFiles()
    #expect(again.pending.map(\.path) == files.dropFirst().map(\.path))
    #expect(again.done == 1 && again.total == files.count && again.unfinished)
    // Carrying on keeps the run's start.
    try relaunched.beginAnalysisRun(again: false)
    #expect(try relaunched.analysisFiles().pending.count == files.count - 1)
    for file in files.dropFirst() {
        try relaunched.recordAnalysisFailure(path: file.path, stamp: file.stamp)
    }
    try relaunched.finishAnalysisRun()
    done = try relaunched.analysisFiles()
    #expect(done.failed == files.count - 1 && done.pending.isEmpty && !done.unfinished)
    #expect(done.tried == files.count)
    // Carrying on keeps the failures, out of what's left; a run again tries them.
    try relaunched.beginAnalysisRun(again: false)
    #expect(try relaunched.analysisFiles().failed == files.count - 1)
    try relaunched.beginAnalysisRun(again: true, now: Date(timeIntervalSince1970: 4_000))
    let fresh = try relaunched.analysisFiles()
    #expect(fresh.failed == 0 && fresh.pending.count == files.count)
}

/// Measures stored before the run's tables were added count as done, so the owner's library
/// isn't read again.
@Test func measuresFromBeforeTheRunsTablesCountAsDone() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let files = try index.analysisFiles().pending
    for file in files { try index.storeMeasures(measured, path: file.path, stamp: file.stamp) }
    try index.database.execute(
        """
        DROP TABLE \(analysisRunTable); DROP TABLE \(measuredAtTable);
        DROP TABLE \(analysisFailuresTable);
        DELETE FROM schema_identity WHERE part = '\(SchemaPart.analysisRun.rawValue)'
        """)

    let added = try library.index()
    let after = try added.analysisFiles()
    #expect(after.pending.isEmpty && after.done == files.count && !after.unfinished)
    #expect(try added.discards().isEmpty)
}
