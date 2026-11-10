import Foundation
import Testing

@testable import Analysis
@testable import Fixtures

private func fixture(_ fixture: AnalysisFixture) throws -> String {
    try analysisFixture(fixture, in: try defaultPlaybackFixturesDirectory()).path
}

@Test func aCleanStagedFileDoesntBlockApprove() async throws {
    // Padded bits say nothing of where the audio came from.
    let origins = try await stagedOrigins([try fixture(.fullBand), try fixture(.padded)])
    #expect(origins.map(\.verdicts) == [[], []])
    #expect(!origins.contains { $0.blocks })
}

@Test func anUpsampledOrLossyOriginStagedFileBlocksApprove() async throws {
    let origins = try await stagedOrigins([try fixture(.upsampled), try fixture(.aacRoundTrip)])
    #expect(origins.map { $0.verdicts.map(\.kind) } == [[.upsampled], [.lossyOrigin]])
    #expect(origins.allSatisfy { $0.blocks })
}

@Test func aStagedFileThatCantBeAnalyzedBlocksApprove() async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("staged-origin-\(UUID().uuidString).flac").path
    try Data("not audio".utf8).write(to: URL(fileURLWithPath: path, isDirectory: false))
    defer { try? FileManager.default.removeItem(atPath: path) }
    let origins = try await stagedOrigins([path])
    #expect(origins.first?.failure != nil)
    #expect(origins.first?.blocks == true)
}

@Test func theFirstAndLastStagedFilesAreAnalyzed() async throws {
    let paths = [try fixture(.fullBand), try fixture(.padded), try fixture(.upsampled)]
    let analyzed = try await stagedOrigins(paths).map(\.path)
    #expect(analyzed == [paths[0], paths[2]])
}

@Test func cancellingTheTaskStopsTheCheck() async throws {
    let paths = [try fixture(.fullBand), try fixture(.padded)]
    let task = Task { try await stagedOrigins(paths) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func theTwoStagedFilesAreAnalyzedAtOnceAndReportedInOrder() async throws {
    let paths = [try fixture(.upsampled), try fixture(.aacRoundTrip)]
    // Each file's analysis waits for the other's to start, so one after the other would time
    // out; the first is held back until the last is done, so the order isn't the finishing one.
    let started = paths.map { _ in DispatchSemaphore(value: 0) }
    let lastDone = DispatchSemaphore(value: 0)
    let origins = try await stagedOrigins(paths) { url in
        let index = paths.firstIndex(of: url.path)!
        started[index].signal()
        guard started[1 - index].wait(timeout: .now() + 10) == .success else {
            throw CocoaError(.featureUnsupported)
        }
        if index == 0 {
            guard lastDone.wait(timeout: .now() + 10) == .success else {
                throw CocoaError(.featureUnsupported)
            }
        }
        let result = try analyzeFile(at: url)
        if index == 1 { lastDone.signal() }
        return result
    }
    #expect(origins.map(\.path) == paths)
    #expect(origins.map(\.failure) == [nil, nil])
    #expect(origins.map { $0.verdicts.map(\.kind) } == [[.upsampled], [.lossyOrigin]])
}
