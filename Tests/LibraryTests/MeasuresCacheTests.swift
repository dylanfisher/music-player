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

@Test func measuresComeBackForTheSameFile() async throws {
    let library = try TestLibrary()
    let cache = try MeasuresCache(databaseURL: library.databaseURL)
    try await cache.store(measured, path: "/a.flac", stamp: stamp)
    try await cache.store(silent, path: "/b.m4a", stamp: stamp)
    #expect(try await cache.measures(path: "/a.flac", stamp: stamp) == measured)
    #expect(try await cache.measures(path: "/b.m4a", stamp: stamp) == silent)
    #expect(try await cache.measures(path: "/c.flac", stamp: stamp) == nil)
}

@Test func measuresOfAChangedFileAreIgnoredAndReplaced() async throws {
    let library = try TestLibrary()
    let cache = try MeasuresCache(databaseURL: library.databaseURL)
    try await cache.store(measured, path: "/a.flac", stamp: stamp)
    let grown = FileStamp(sizeBytes: stamp.sizeBytes + 1, modifiedSeconds: stamp.modifiedSeconds)
    let touched = FileStamp(sizeBytes: stamp.sizeBytes, modifiedSeconds: stamp.modifiedSeconds + 1)
    #expect(try await cache.measures(path: "/a.flac", stamp: grown) == nil)
    #expect(try await cache.measures(path: "/a.flac", stamp: touched) == nil)
    try await cache.store(silent, path: "/a.flac", stamp: touched)
    #expect(try await cache.measures(path: "/a.flac", stamp: touched) == silent)
    #expect(try await cache.measures(path: "/a.flac", stamp: stamp) == nil)
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
