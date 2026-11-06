import Foundation
import Testing

@testable import Analysis
@testable import Fixtures

/// A 16-bit 44.1 kHz stereo WAV in a folder of its own, its samples from -1 to 1.
private func wav(frames: Int, _ value: (Int, Int) -> Double) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("analysis-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("test.wav")
    try writeWAV(at: url, sampleRateHz: 44_100, bitsPerSample: 16, frames: frames) {
        Int32(max(-32768, min(32767, (value($0, $1) * 32768).rounded())))
    }
    return url
}

@Test func theTruePeakFindsTheCrestBetweenSamples() throws {
    // A quarter of the rate, 45° out: every sample is at 0.707 of the crest.
    let url = try wav(frames: 44_100) { frame, _ in
        0.5 * sin(.pi / 2 * Double(frame) + .pi / 4)
    }
    let measures = try analyzeFile(at: url).measures
    let peak = try #require(measures.peakDBFS)
    let truePeak = try #require(measures.truePeakDBTP)
    #expect(abs(peak - 20 * log10(0.5 * 0.5.squareRoot())) < 0.01)
    #expect(abs(truePeak - 20 * log10(0.5)) < 0.2, "\(truePeak)")
}

@Test func theDynamicRangeIsTheSecondPeakOverTheLoudestBlocks() throws {
    // A sine at half scale, whose RMS the meters take as 0.5, with a full-scale sample in two
    // of its eight 3-second blocks: 20 log10(1 / 0.5).
    let block = 3 * 44_100
    let url = try wav(frames: 8 * block) { frame, _ in
        frame == block + 10 || frame == 5 * block + 10
            ? 1 : 0.5 * sin(2 * .pi * 1000 * Double(frame) / 44_100)
    }
    let measures = try analyzeFile(at: url).measures
    #expect(measures.dynamicRange == 6)
    #expect(measures.clippedRuns == 0)
}

@Test func runsUnderThreeSamplesAtFullScaleArentClipped() throws {
    // Runs of 2 and of 3 on the left, a run of 4 that ends the file on the right.
    let frames = 20_000
    let url = try wav(frames: frames) { frame, channel in
        switch (channel, frame) {
        case (0, 100...101), (0, 200...202): 1
        case (1, frames - 4..<frames): -1
        default: 0.1
        }
    }
    #expect(try analyzeFile(at: url).measures.clippedRuns == 2)
}

@Test func aFileShorterThanAWindowIsOneColumn() throws {
    let url = try wav(frames: 1000) { frame, _ in 0.25 * sin(Double(frame)) }
    let result = try analyzeFile(at: url)
    #expect(result.spectrogram.columns == 1)
    #expect(result.spectrogram.cells.count == Spectrogram.rows)
    #expect(abs(result.measures.durationSeconds - 1000 / 44_100) < 1e-9)
}

@Test func silenceHasNoLevelsAndNoVerdicts() throws {
    let url = try wav(frames: 20_000) { _, _ in 0 }
    let measures = try analyzeFile(at: url).measures
    #expect(measures.peakDBFS == nil && measures.truePeakDBTP == nil)
    #expect(measures.effectiveBits == nil && measures.dynamicRange == nil)
    #expect(measures.identicalChannels == true)
    #expect(verdicts(measures).isEmpty)
}

@Test func aDSDFileIsSkippedAndSaysSo() throws {
    #expect(throws: AnalysisError.dsd) {
        try analyzeFile(at: URL(fileURLWithPath: "/x.dsf", isDirectory: false))
    }
    #expect("\(AnalysisError.dsd)" == "DSD files aren't analyzed yet")
}

@Test func cancellingStopsAtTheNextFFTFrame() async throws {
    let url = try analysisFixture(.fullBand, in: try defaultPlaybackFixturesDirectory())
    let reports = Reports()
    let task = Task {
        try analyzeFile(at: url) { share in
            reports.append(share)
            if share >= 0.25 { withUnsafeCurrentTask { $0?.cancel() } }
        }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    // A frame is 1.5% of the file, and progress comes each hundredth.
    let last = try #require(reports.values.last)
    #expect(last >= 0.25 && last <= 0.27, "\(reports.values)")
}

private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var shares: [Double] = []

    func append(_ share: Double) { lock.withLock { shares.append(share) } }
    var values: [Double] { lock.withLock { shares } }
}
