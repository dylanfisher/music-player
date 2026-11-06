import Library
import Testing

@testable import Analysis

/// A clean 16/44.1 FLAC's measures, for each test to change one of.
private func clean(_ change: (inout FileMeasures) -> Void = { _ in }) -> FileMeasures {
    var measures = FileMeasures(
        formatID: "flac", sampleRateHz: 44_100, storedBits: 16, channels: 2, isFloat: false,
        durationSeconds: 200, cutoffHz: nil, cutoffSteepnessDBPerKHz: nil, effectiveBits: 16,
        identicalChannels: false, peakDBFS: -0.5, truePeakDBTP: -0.2, clippedRuns: 0,
        dynamicRange: 9)
    change(&measures)
    return measures
}

private func kinds(_ measures: FileMeasures) -> [Verdict.Kind] { verdicts(measures).map(\.kind) }

@Test func aCleanFileHasNoVerdict() {
    #expect(verdicts(clean()).isEmpty)
}

@Test func aLosslessFileCutAtOrUnder20_5kHzIsSuspectLossy() {
    #expect(kinds(clean { $0.cutoffHz = 20_500 }) == [.lossyOrigin])
    #expect(kinds(clean { $0.cutoffHz = 20_600 }).isEmpty)
    #expect(
        verdicts(clean { $0.cutoffHz = 16_000 }).map(\.text) == [
            "Cutoff at 16.0 kHz: suspect conversion from a lossy file"
        ])
    for format in ["alac", "lpcm"] {
        #expect(
            kinds(
                clean {
                    $0.formatID = format
                    $0.cutoffHz = 16_000
                }) == [.lossyOrigin])
    }
}

@Test func aLossyFileOrALowRateGetsNoLossyVerdict() {
    for format in ["aac ", ".mp3"] {
        #expect(
            kinds(
                clean {
                    $0.formatID = format
                    $0.cutoffHz = 16_000
                }
            ).isEmpty)
    }
    // A 32 kHz file's Nyquist is 16 kHz, so content stopping under it is no sign.
    #expect(
        kinds(
            clean {
                $0.sampleRateHz = 32_000
                $0.cutoffHz = 15_000
            }
        ).isEmpty)
}

@Test func aHighRateFileWhoseContentStopsByTwentyFourKHzIsSuspectUpsampled() {
    let upsampled = clean {
        $0.sampleRateHz = 96_000
        $0.storedBits = 24
        $0.effectiveBits = 24
        $0.cutoffHz = 22_050
    }
    #expect(kinds(upsampled) == [.upsampled])
    #expect(
        verdicts(upsampled).map(\.text) == [
            "Content stops at 22.1 kHz in a 96 kHz file: suspect upsampled"
        ])
    #expect(
        kinds(
            clean {
                $0.sampleRateHz = 96_000
                $0.cutoffHz = 24_000
            }) == [.upsampled])
    #expect(
        kinds(
            clean {
                $0.sampleRateHz = 96_000
                $0.cutoffHz = 24_100
            }
        ).isEmpty)
    // 48 kHz isn't over 48 kHz.
    #expect(
        kinds(
            clean {
                $0.sampleRateHz = 48_000
                $0.cutoffHz = 22_000
            }
        ).isEmpty)
    // A lossy origin at a high rate is both.
    #expect(
        kinds(
            clean {
                $0.sampleRateHz = 96_000
                $0.cutoffHz = 16_000
            }) == [
                .lossyOrigin, .upsampled,
            ])
}

@Test func fewerEffectiveBitsThanStoredArePadded() {
    let padded = clean {
        $0.storedBits = 24
        $0.effectiveBits = 16
    }
    #expect(kinds(padded) == [.paddedBits])
    #expect(
        verdicts(padded).map(\.text) == ["16 effective bits of 24 stored: padded with zero bits"])
    #expect(
        kinds(
            clean {
                $0.storedBits = 24
                $0.effectiveBits = 24
            }
        ).isEmpty)
    #expect(
        kinds(
            clean {
                $0.storedBits = nil
                $0.effectiveBits = nil
            }
        ).isEmpty)
}

@Test func identicalChannelsAreFakeStereoUnlessSilent() {
    #expect(kinds(clean { $0.identicalChannels = true }) == [.fakeStereo])
    #expect(kinds(clean { $0.identicalChannels = nil }).isEmpty)
    #expect(
        kinds(
            clean {
                $0.identicalChannels = true
                $0.peakDBFS = nil
            }
        ).isEmpty)
}

@Test func tenClippedRunsAreClipped() {
    #expect(kinds(clean { $0.clippedRuns = 10 }) == [.clipped])
    #expect(kinds(clean { $0.clippedRuns = 9 }).isEmpty)
    #expect(
        verdicts(clean { $0.clippedRuns = 1204 }).map(\.text) == [
            "1,204 runs of 3 or more samples at full scale: clipped"
        ])
}

@Test func aCutoffIsASteepFallThatStaysDown() throws {
    let rowHz = 22_050.0 / Double(Spectrogram.rows)
    let edge = 372
    let cliff = (0..<Spectrogram.rows).map { $0 < edge ? -60.0 : -140 }
    let cutoff = try #require(Cutoff(rowDB: cliff, rowHz: rowHz))
    #expect(cutoff.frequencyHz == Double(edge) * rowHz)
    // 80 dB between the means of the half spans, 12 rows (517 Hz) apart.
    #expect(abs(cutoff.steepnessDBPerKHz - 80 / (12 * rowHz / 1000)) < 0.01)
    // A fall of under 20 dB across the span isn't one, however low it ends.
    let slope = (0..<Spectrogram.rows).map { -60 - 1.5 * Double($0) }
    #expect(Cutoff(rowDB: slope, rowHz: rowHz) == nil)
    // Nor is one under 5 kHz.
    let low = (0..<Spectrogram.rows).map { $0 < 50 ? -60.0 : -140 }
    #expect(Cutoff(rowDB: low, rowHz: rowHz) == nil)
    // With two, the higher one is the cutoff.
    let two = (0..<Spectrogram.rows).map { $0 < 300 ? -40.0 : $0 < edge ? -70 : -140 }
    #expect(try #require(Cutoff(rowDB: two, rowHz: rowHz)).frequencyHz == Double(edge) * rowHz)
}
