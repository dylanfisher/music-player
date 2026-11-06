import Foundation
import Testing

@testable import Analysis
@testable import Fixtures

/// What each generated fixture should be found to be: one verdict for each problem it was
/// made with, none for a clean one.
private let expected: [AnalysisFixture: [Verdict.Kind]] = [
    .fullBand: [],
    .lowPass16k: [.lossyOrigin],
    .lowPass19k: [.lossyOrigin],
    // A lossy file gets no lossy-origin verdict; the same audio in a FLAC does.
    .aac: [],
    .aacRoundTrip: [.lossyOrigin],
    .upsampled: [.upsampled],
    .padded: [.paddedBits],
    .identicalChannels: [.fakeStereo],
    .clipped: [.clipped],
    .hiRes: [],
]

private func analyzed(_ fixture: AnalysisFixture) throws -> AnalysisResult {
    try analyzeFile(at: try analysisFixture(fixture, in: try defaultPlaybackFixturesDirectory()))
}

@Test(arguments: AnalysisFixture.allCases)
func eachFixtureGetsTheVerdictsItWasMadeFor(_ fixture: AnalysisFixture) throws {
    let measures = try analyzed(fixture).measures
    #expect(verdicts(measures).map(\.kind) == expected[fixture], "\(measures)")
}

@Test func theLowPassedFixturesCutOffWhereTheyWereCut() throws {
    for (fixture, hertz) in [(AnalysisFixture.lowPass16k, 16_000.0), (.lowPass19k, 19_000)] {
        let measures = try analyzed(fixture).measures
        let cutoff = try #require(measures.cutoffHz)
        // Within a row of the spectrum, 43 Hz at 44.1 kHz.
        #expect(abs(cutoff - hertz) < 50, "\(fixture)")
        #expect(try #require(measures.cutoffSteepnessDBPerKHz) > 100, "\(fixture)")
        #expect(
            verdicts(measures).first?.text.hasPrefix("Cutoff at \(Int(hertz / 1000)).0 kHz") == true
        )
    }
    let upsampled = try analyzed(.upsampled).measures
    #expect(abs(try #require(upsampled.cutoffHz) - 22_050) < 100)
}

@Test func effectiveBitsCountTheBitsSamplesUse() throws {
    #expect(try analyzed(.fullBand).measures.effectiveBits == 16)
    #expect(try analyzed(.hiRes).measures.effectiveBits == 24)
    let padded = try analyzed(.padded).measures
    #expect(padded.storedBits == 24 && padded.effectiveBits == 16)
}

@Test func theCleanFixturesMeasureAsNoiseAt20dBUnderFullScale() throws {
    for fixture in [AnalysisFixture.fullBand, .hiRes] {
        let measures = try analyzed(fixture).measures
        #expect(measures.cutoffHz == nil, "\(fixture)")
        #expect(measures.identicalChannels == false)
        #expect(measures.clippedRuns == 0)
        // Gaussian noise peaks about 13 dB over its RMS, which the DR score takes 3 dB off.
        let peak = try #require(measures.peakDBFS)
        #expect((-9.0 ... -5.0).contains(peak), "\(peak)")
        #expect(try #require(measures.truePeakDBTP) >= peak)
        #expect((8...12).contains(try #require(measures.dynamicRange)))
    }
}

@Test func theAACFileItselfGetsMeasuresButNoLossyVerdict() throws {
    let measures = try analyzed(.aac).measures
    #expect(measures.formatID == "aac ")
    #expect(measures.storedBits == nil && measures.effectiveBits == nil && measures.isFloat)
    #expect(try #require(measures.cutoffHz) < 20_000)
    #expect(verdicts(measures).isEmpty)
}

@Test func theSpectrogramShowsTheCutoff() throws {
    let spectrogram = try analyzed(.lowPass16k).spectrogram
    #expect(spectrogram.nyquistHz == 22_050)
    #expect(abs(spectrogram.durationSeconds - Double(analysisFixtureSeconds)) < 0.01)
    // 6 s at 44.1 kHz is 63 windows, fewer than the most columns.
    #expect(spectrogram.columns == 63)
    let below = (0..<Spectrogram.rows).first { spectrogram.frequencyHz(row: $0) > 10_000 }!
    let above = (0..<Spectrogram.rows).first { spectrogram.frequencyHz(row: $0) > 17_000 }!
    for column in 0..<spectrogram.columns {
        #expect(spectrogram.level(column: column, row: below) > -70)
        #expect(spectrogram.level(column: column, row: above) < -120)
    }
    #expect(spectrogram.averageDB[below] > -70 && spectrogram.averageDB[above] < -120)
}
