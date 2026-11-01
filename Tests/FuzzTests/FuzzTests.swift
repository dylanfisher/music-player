import Fixtures
import Foundation
import FuzzCoverage
import Testing

@testable import Fuzz

@Test func coverageCountsEachEdgeAndHitBucketOnce() {
    var guards = [UInt32](repeating: 0, count: 3)
    guards.withUnsafeMutableBufferPointer { buffer in
        let start = buffer.baseAddress!
        FuzzCoverageTestInit(start, start + 3)
        #expect(buffer[0] != 0 && buffer[1] == buffer[0] + 1 && buffer[2] == buffer[1] + 1)
        let before = FuzzCoverageFeatureCount()

        FuzzCoverageClear()
        FuzzCoverageTestHit(start)
        FuzzCoverageTestHit(start + 1)
        FuzzCoverageTestHit(start + 1)
        #expect(FuzzCoverageNewFeatures(0) == 2)
        // Without `keep` they weren't recorded, so they're new again.
        FuzzCoverageTestHit(start)
        FuzzCoverageTestHit(start + 1)
        FuzzCoverageTestHit(start + 1)
        #expect(FuzzCoverageNewFeatures(1) == 2)
        #expect(FuzzCoverageFeatureCount() == before + 2)

        FuzzCoverageTestHit(start)
        FuzzCoverageTestHit(start + 1)
        FuzzCoverageTestHit(start + 1)
        #expect(FuzzCoverageNewFeatures(1) == 0)
        // A third hit is a new bucket for that edge; the count was cleared by the last call.
        for _ in 0..<3 { FuzzCoverageTestHit(start + 1) }
        #expect(FuzzCoverageNewFeatures(1) == 1)
        // Hits before a clear don't count.
        FuzzCoverageTestHit(start + 2)
        FuzzCoverageClear()
        #expect(FuzzCoverageNewFeatures(1) == 0)
    }
}

@Test func mutationsRepeatWithTheSeedAndStayUnderTheCap() {
    func mutations(_ seed: UInt64) -> [[UInt8]] {
        var mutator = Mutator(seed: seed, maximumBytes: 64, tokens: [Array("TITLE=".utf8)])
        var input = Array("fLaC and some bytes".utf8)
        return (0..<500).map { _ in
            input = mutator.mutate(input, splicing: Array(repeating: 0xAB, count: 40))
            return input
        }
    }
    let first = mutations(7)
    #expect(first == mutations(7))
    #expect(first != mutations(8))
    #expect(first.allSatisfy { $0.count <= 64 })
    #expect(Set(first).count > 400)
}

@Test func minimisingKeepsOnlyWhatTheFailureNeeds() {
    let input = Array("aaaaXbbbbbbbYcccc".utf8)
    let minimised = minimise(input, attempts: 1000) { candidate in
        guard let x = candidate.firstIndex(of: UInt8(ascii: "X")) else { return false }
        return candidate[x...].contains(UInt8(ascii: "Y"))
    }
    #expect(minimised == Array("XY".utf8))
    #expect(minimise(input, attempts: 3) { _ in true }.count < input.count)
    #expect(minimise([], attempts: 10) { _ in true } == [])
}

@Test func findsTheVorbisCommentBlocksOfAFLACFile() {
    let streamInfo: [UInt8] = [0x00, 0, 0, 2, 0xAA, 0xBB]
    let comment: [UInt8] = [0x84, 0, 0, 3, 1, 2, 3]
    let file = Array("fLaC".utf8) + streamInfo + comment + [9, 9]
    #expect(vorbisBlocks(file) == [[1, 2, 3]])
    #expect(vorbisBlocks(Array("RIFF".utf8)) == [])
    // A block whose length runs past the end is cut at the end.
    #expect(vorbisBlocks(Array("fLaC".utf8) + [0x84, 0, 0, 9, 1]) == [[1]])
}

@Test func harvestsRecurringIDsAndQuotedKeys() {
    let tokens = harvestTokens([
        Array("..moov....moov..trak".utf8), Array("{\"key\": 1, \"key\": 2}".utf8),
    ])
    #expect(tokens.contains(Array("moov".utf8)))
    #expect(tokens.contains(Array("\"key\"".utf8)))
    #expect(!tokens.contains(Array("trak".utf8)))
}

private let library = Result { () throws -> URL in
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/fuzz-tests")
    _ = try generateFixtures(count: coveringLibraryFileCount, in: root)
    return root
}

private func scratchFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("fuzz-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// Every target sets up, takes its good seeds and refuses garbage without tripping its checks.
@MainActor @Test(arguments: FuzzTarget.all.map(\.name))
func eachTargetAcceptsItsSeedsAndRefusesGarbage(_ name: String) throws {
    let target = try #require(FuzzTarget.named(name))
    let work = try scratchFolder()
    let library = try library.get()
    var seeds = try seedFiles(for: target, in: [library]).prefix(20).flatMap(target.seedInputs)
    seeds += try target.madeSeeds(work, library)
    #expect(!seeds.isEmpty)
    let run = try target.prepare(work)
    let accepted = seeds.filter { run($0) }.count
    // Generated files include malformed ones, which are refused.
    #expect(accepted * 2 >= seeds.count, "\(accepted) of \(seeds.count) accepted")
    #expect(!run(Array("not any format at all".utf8)))
    #expect(!run([]))
}
