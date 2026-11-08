import Foundation
import Testing

@testable import Analysis
@testable import Fixtures

private func fixture(_ fixture: AnalysisFixture) throws -> String {
    try analysisFixture(fixture, in: try defaultPlaybackFixturesDirectory()).path
}

@Test func aCleanStagedFileDoesntBlockApprove() throws {
    // Padded bits say nothing of where the audio came from.
    let origins = try stagedOrigins([try fixture(.fullBand), try fixture(.padded)])
    #expect(origins.map(\.verdicts) == [[], []])
    #expect(!origins.contains { $0.blocks })
}

@Test func anUpsampledOrLossyOriginStagedFileBlocksApprove() throws {
    let origins = try stagedOrigins([try fixture(.upsampled), try fixture(.aacRoundTrip)])
    #expect(origins.map { $0.verdicts.map(\.kind) } == [[.upsampled], [.lossyOrigin]])
    #expect(origins.allSatisfy { $0.blocks })
}

@Test func aStagedFileThatCantBeAnalyzedBlocksApprove() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("staged-origin-\(UUID().uuidString).flac").path
    try Data("not audio".utf8).write(to: URL(fileURLWithPath: path, isDirectory: false))
    defer { try? FileManager.default.removeItem(atPath: path) }
    let origins = try stagedOrigins([path])
    #expect(origins.first?.failure != nil)
    #expect(origins.first?.blocks == true)
}

@Test func theFirstAndLastStagedFilesAreAnalyzed() throws {
    let paths = [try fixture(.fullBand), try fixture(.padded), try fixture(.upsampled)]
    let analyzed = try stagedOrigins(paths).map(\.path)
    #expect(analyzed == [paths[0], paths[2]])
}
