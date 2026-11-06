import Foundation
import Metadata
import Testing

@testable import Analysis
@testable import Fixtures
@testable import Library

/// A folder of its own holding a copy of a fixture, a library and a spectrogram store.
private struct Scratch {
    let directory: URL
    let file: URL
    let store: SpectrogramStore
    let analyzer: FileAnalyzer

    init(_ fixture: AnalysisFixture = .lowPass16k) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("analyzer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("track.flac")
        try FileManager.default.copyItem(
            at: try analysisFixture(fixture, in: try defaultPlaybackFixturesDirectory()), to: file)
        store = SpectrogramStore(directory: directory.appendingPathComponent("Spectrograms"))
        analyzer = FileAnalyzer(
            measures: try MeasuresCache(
                databaseURL: libraryFileURL(in: directory.appendingPathComponent("data"))),
            spectrograms: store)
    }

    func storedFiles() throws -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []
    }
}

private final class Shares: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [Double] = []

    func append(_ share: Double) { lock.withLock { all.append(share) } }
    var values: [Double] { lock.withLock { all } }
}

@Test func aSecondLookComesFromTheCaches() async throws {
    let scratch = try Scratch()
    let first = Shares()
    let analyzed = try await scratch.analyzer.result(of: scratch.file.path) { first.append($0) }
    #expect(first.values.count > 10)
    #expect(try scratch.storedFiles().count == 1)
    let second = Shares()
    let cached = try await scratch.analyzer.result(of: scratch.file.path) { second.append($0) }
    #expect(second.values == [1])
    #expect(cached == analyzed)
    let measuresOnly = Shares()
    #expect(
        try await scratch.analyzer.measures(of: scratch.file.path) { measuresOnly.append($0) }
            == analyzed.measures)
    #expect(measuresOnly.values == [1])
}

@Test func aChangedFileIsAnalyzedAgain() async throws {
    let scratch = try Scratch()
    let before = try await scratch.analyzer.result(of: scratch.file.path)
    // Another file at the same path, with another size and modification time.
    try FileManager.default.removeItem(at: scratch.file)
    try FileManager.default.copyItem(
        at: try analysisFixture(.fullBand, in: try defaultPlaybackFixturesDirectory()),
        to: scratch.file)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: scratch.file.path)
    let after = try await scratch.analyzer.result(of: scratch.file.path)
    #expect(before.measures.cutoffHz != nil && after.measures.cutoffHz == nil)
    #expect(try scratch.storedFiles().count == 2)
}

@Test func aMissingSpectrogramIsMadeAgainFromTheFile() async throws {
    let scratch = try Scratch()
    let analyzed = try await scratch.analyzer.result(of: scratch.file.path)
    for name in try scratch.storedFiles() {
        try FileManager.default.removeItem(at: scratch.store.directory.appendingPathComponent(name))
    }
    let shares = Shares()
    #expect(
        try await scratch.analyzer.result(of: scratch.file.path) { shares.append($0) } == analyzed)
    #expect(shares.values.count > 10)
}

@Test func aMeasuresCacheThatFailsIsLoggedAndTheAnalysisStillReturned() async throws {
    let scratch = try Scratch()
    // The table gone, as a cache the index can't read or write.
    try LibraryIndex(at: libraryFileURL(in: scratch.directory.appendingPathComponent("data")))
        .database.execute("DROP TABLE measures")
    let shares = Shares()
    let result = try await scratch.analyzer.result(of: scratch.file.path) { shares.append($0) }
    #expect(result.measures.cutoffHz != nil)
    #expect(shares.values.count > 10)
    #expect(try await scratch.analyzer.measures(of: scratch.file.path) == result.measures)
}

@Test func aMissingFileFails() async throws {
    let scratch = try Scratch()
    await #expect(throws: (any Error).self) {
        try await scratch.analyzer.measures(
            of: scratch.directory.appendingPathComponent("none.flac").path)
    }
}

@Test func cancellingTheCallerCancelsTheAnalysis() async throws {
    let scratch = try Scratch(.hiRes)
    let task = Task { try await scratch.analyzer.result(of: scratch.file.path) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func aSpectrogramRoundTripsThroughItsFile() throws {
    let spectrogram = Spectrogram(
        columns: 3, cells: (0..<3 * Spectrogram.rows).map { UInt8($0 % 256) },
        averageDB: (0..<Spectrogram.rows).map { -Float($0) / 4 }, nyquistHz: 48_000,
        durationSeconds: 12.5)
    #expect(SpectrogramStore.decode(SpectrogramStore.encode(spectrogram)) == spectrogram)
    // Bytes of any other length are an earlier shape, or damage.
    #expect(SpectrogramStore.decode(SpectrogramStore.encode(spectrogram).dropLast()) == nil)
    #expect(SpectrogramStore.decode(Data()) == nil)
}

@Test func aSpectrogramThatDoesntDecodeIsRemoved() throws {
    let scratch = try Scratch()
    let stamp = FileStamp(sizeBytes: 1, modifiedSeconds: 2)
    try FileManager.default.createDirectory(
        at: scratch.store.directory, withIntermediateDirectories: true)
    let url = scratch.store.fileURL(path: "/x.flac", stamp: stamp)
    try Data([1, 2, 3]).write(to: url)
    #expect(scratch.store.spectrogram(path: "/x.flac", stamp: stamp) == nil)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func theStoreRemovesTheLeastRecentlyUsedPastItsCapacity() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("spectrograms-\(UUID().uuidString)")
    let spectrogram = Spectrogram(
        columns: 10, cells: Array(repeating: 9, count: 10 * Spectrogram.rows),
        averageDB: Array(repeating: -60, count: Spectrogram.rows), nyquistHz: 22_050,
        durationSeconds: 1)
    let size = SpectrogramStore.encode(spectrogram).count
    let store = SpectrogramStore(directory: directory, capacityBytes: 2 * size)
    let stamps = (0..<3).map { FileStamp(sizeBytes: $0, modifiedSeconds: 0) }
    for (index, stamp) in stamps.enumerated() {
        store.store(spectrogram, path: "/a.flac", stamp: stamp)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: Double(1000 + index))],
            ofItemAtPath: store.fileURL(path: "/a.flac", stamp: stamp).path)
    }
    // Reading the oldest marks it used, so the second goes instead.
    #expect(store.spectrogram(path: "/a.flac", stamp: stamps[0]) == spectrogram)
    store.trim()
    #expect(store.spectrogram(path: "/a.flac", stamp: stamps[0]) != nil)
    #expect(store.spectrogram(path: "/a.flac", stamp: stamps[1]) == nil)
    #expect(store.spectrogram(path: "/a.flac", stamp: stamps[2]) != nil)
}
