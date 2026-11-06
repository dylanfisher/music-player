import Foundation
import Library
import Testing

@testable import Analysis
@testable import Fixtures

/// Music's usual slope, about pink: -20 dB at 1 kHz, 10 dB less each decade up.
private func pink(_ hertz: Double) -> Double { -20 - 10 * log10(max(hertz, 20) / 1000) }

/// A 4:16 file named `name`, a clean 16-bit FLAC at 44.1 kHz unless told otherwise, whose
/// average spectrum is `level` at each row's frequency at 44.1 kHz. A bin is as many hertz
/// wide as the rate is over 44.1 kHz, so holds as much more of the same sound.
private func compared(
    _ name: String, formatID: String = "flac", rateHz: Double = 44_100, storedBits: Int? = 16,
    effectiveBits: Int? = 16, cutoffHz: Double? = nil, durationSeconds: Double = 256,
    truePeakDBTP: Double = -0.3, clippedRuns: Int = 0, dynamicRange: Int? = 11,
    sizeBytes: Int? = nil, channels: Int = 2, peakDBFS: Double? = -0.5,
    level: (Double) -> Double = pink
) -> ComparedFile {
    let nyquist = rateHz / 2
    let average = (0..<Spectrogram.rows).map { row in
        let hertz = (Double(row) + 0.5) * nyquist / Double(Spectrogram.rows)
        let binDB = level(hertz) + 10 * log10(rateHz / 44_100)
        return Float(cutoffHz.map { hertz >= $0 ? -140 : binDB } ?? binDB)
    }
    let measures = FileMeasures(
        formatID: formatID, sampleRateHz: rateHz, storedBits: storedBits, channels: channels,
        isFloat: storedBits == nil, durationSeconds: durationSeconds, cutoffHz: cutoffHz,
        cutoffSteepnessDBPerKHz: cutoffHz.map { _ in 150 }, effectiveBits: effectiveBits,
        identicalChannels: false, peakDBFS: peakDBFS, truePeakDBTP: truePeakDBTP,
        clippedRuns: clippedRuns, dynamicRange: dynamicRange)
    let spectrogram = Spectrogram(
        columns: 1, cells: [UInt8](repeating: 0, count: Spectrogram.rows), averageDB: average,
        nyquistHz: nyquist, durationSeconds: durationSeconds)
    return ComparedFile(
        name: name, openingName: name.prefix(1).uppercased() + name.dropFirst(),
        result: AnalysisResult(measures: measures, spectrogram: spectrogram),
        sizeBytes: sizeBytes)
}

@Test func aWAVAndAFLACOfOneMasterDifferOnlyInHowTheyreStored() {
    // The owner's two copies of "So Many Questions": the 16-bit WAV a little higher above
    // 16 kHz, as noise-shaped dither puts it.
    let wav = compared(
        "the WAV", formatID: "lpcm", sizeBytes: 45_158_000,
        level: { pink($0) + ($0 >= 16_000 ? 2 : 0) })
    let flac = compared("the FLAC", storedBits: 24, effectiveBits: 24, sizeBytes: 41_000_000)
    #expect(
        differences(flac, from: wav) == [
            "The WAV has about 2 dB more above 16 kHz than the FLAC, where music has little:"
                + " probably noise-shaped dither, added when it was made 16-bit",
            "The FLAC holds 24 bits of detail and the WAV 16: the extra bits only hold sound"
                + " more than 96 dB under full scale, too quiet to hear at a normal volume",
            "The FLAC is compressed without loss and the WAV is uncompressed: either way every"
                + " sample is kept, so the format alone changes nothing you hear",
            "The FLAC is 41 MB and the WAV 45.2 MB: a lossless file's size follows its format,"
                + " bits and rate, not how it sounds",
            "The FLAC and the WAV sound the same as far as these measures can tell: only"
                + " comparing their samples could prove the audio identical",
        ])
}

@Test func aCopyMadeFromALossyFileStopsLower() {
    let original = compared("Original")
    let copy = compared("Copy", cutoffHz: 16_000)
    #expect(
        differences(copy, from: original) == [
            "Copy stops at 16.0 kHz and Original goes on to 22.05 kHz: Copy was probably made"
                + " from an MP3 or AAC file"
        ])
    // The same, the other way round: whichever stops lower is the one named.
    #expect(differences(original, from: copy).first?.hasPrefix("Copy stops at 16.0 kHz") == true)
}

@Test func aLoudRemasterIsLouderMoreCompressedAndHasMoreBass() {
    let original = compared("Original", dynamicRange: 12)
    let remaster = compared(
        "Remaster", truePeakDBTP: 0.8, clippedRuns: 200, dynamicRange: 6,
        level: { pink($0) + 4 + ($0 < 250 ? 3 : 0) })
    #expect(
        differences(remaster, from: original) == [
            "Remaster is about 5 dB louder overall than Original: turn it down that much to"
                + " compare them fairly, as louder tends to sound better",
            "Remaster's DR is 6 against Original's 12: Remaster is more compressed, its loud"
                + " and quiet moments closer together, typical of a loud remaster",
            "Remaster peaks at +0.8 dBTP between samples, over full scale, and Original stays"
                + " under: Remaster may distort slightly in some players and converters",
            "Remaster has 200 clipped runs and Original 0: Remaster's peaks were probably cut"
                + " off to make it louder",
            "Remaster has about 3 dB more bass than Original, measured against their midrange:"
                + " a different EQ, as remasters often have",
        ])
}

@Test func identicalFilesSoundTheSame() {
    #expect(
        differences(compared("B"), from: compared("A")) == [
            "B and A sound the same as far as these measures can tell: only comparing their"
                + " samples could prove the audio identical"
        ])
}

/// The first sentence of how `file` differs from a clean FLAC, or nil when it's only the
/// closing one.
private func firstDifference(_ file: ComparedFile) -> String? {
    let found = differences(file, from: compared("A"))
    return found.count == 1 && found[0].contains("sound the same") ? nil : found[0]
}

@Test func eachDifferenceNeedsToPassItsThreshold() {
    #expect(firstDifference(compared("B", level: { pink($0) + 0.9 })) == nil)
    #expect(firstDifference(compared("B", level: { pink($0) + 1.1 }))?.contains("louder") == true)
    #expect(firstDifference(compared("B", dynamicRange: 10)) == nil)
    #expect(firstDifference(compared("B", dynamicRange: 9))?.hasPrefix("B's DR is 9") == true)
    #expect(firstDifference(compared("B", durationSeconds: 257.9)) == nil)
    #expect(
        firstDifference(compared("B", durationSeconds: 258.1))
            == "B is 2 seconds longer than A: probably a different edit, a longer fade or more"
            + " silence at the ends")
    #expect(firstDifference(compared("B", truePeakDBTP: 0)) == nil)
    #expect(firstDifference(compared("B", clippedRuns: 9)) == nil)
    // A cutoff a kilohertz under the other file's top, and one just short of that.
    #expect(firstDifference(compared("B", cutoffHz: 21_100)) == nil)
    #expect(
        firstDifference(compared("B", cutoffHz: 21_000))?.hasPrefix("B stops at 21.0 kHz")
            == true)
    let treble = { (extra: Double) in
        compared("B", level: { pink($0) + ($0 >= 4000 && $0 < 16_000 ? extra : 0) })
    }
    #expect(firstDifference(treble(0.9)) == nil)
    #expect(firstDifference(treble(1.1))?.hasPrefix("B has about 1 dB more treble") == true)
}

@Test func paddedBitsAreNoMoreDetail() {
    let padded = compared("B", storedBits: 24, effectiveBits: 16)
    #expect(
        differences(padded, from: compared("A")).first
            == "B is 24-bit but holds 16 bits of detail: no more detail than A")
    #expect(
        differences(padded, from: compared("A", storedBits: 24, effectiveBits: 24)).first
            == "B is 24-bit but holds 16 bits of detail, and A 24: B was probably made from a"
            + " 16-bit copy")
}

@Test func aHigherRateAddsOnlyWhatsAboveTheOthersNyquist() {
    let cd = compared("A")
    #expect(
        differences(compared("B", rateHz: 96_000), from: cd).first
            == "B is at 96 kHz and A at 44.1 kHz: the higher rate adds only sound above 22.05"
            + " kHz, beyond human hearing")
    #expect(
        differences(compared("B", rateHz: 96_000, cutoffHz: 22_000), from: cd).first
            == "B is at 96 kHz and A at 44.1 kHz, but B's sound stops at 22.0 kHz: B was"
            + " probably upsampled, with nothing gained")
}

@Test func anUpsampledFileIsSaidOnceAndOnlyOfALosslessOne() {
    let cd = compared("A")
    // Its content stops at 20 kHz: the rate sentence says it, not the cutoff's too.
    let upsampled = differences(compared("B", rateHz: 96_000, cutoffHz: 20_000), from: cd)
    #expect(upsampled.filter { $0.contains("B's sound stops at 20.0 kHz") }.count == 1)
    #expect(!upsampled.contains { $0.hasPrefix("B stops at") }, "\(upsampled)")
    // A 48 kHz MP3's lowpass is its encoder's, not an upsampling.
    let mp3 = compared(
        "B", formatID: ".mp3", rateHz: 48_000, storedBits: nil, effectiveBits: nil,
        cutoffHz: 16_000)
    let found = differences(mp3, from: cd)
    #expect(found.first?.hasSuffix("B's MP3 encoder dropped the highs to save space") == true)
    #expect(!found.contains { $0.contains("upsampled") }, "\(found)")
}

@Test func aLowRateLosesHighsPeopleHear() {
    #expect(
        differences(compared("B", rateHz: 32_000), from: compared("A")).contains(
            "A is at 44.1 kHz and B at 32 kHz: the higher rate adds only sound above 16 kHz,"
                + " which B can't hold"))
}

@Test func monoAndSilenceAreNotTheSame() {
    let mono = differences(compared("B", channels: 1), from: compared("A"))
    #expect(mono.first == "A is stereo and B mono: they were mixed differently")
    #expect(!mono.contains { $0.contains("sound the same") })
    let silent = differences(compared("B", peakDBFS: nil), from: compared("A"))
    #expect(
        silent.first
            == "B is silent and A isn't: B is probably damaged or the wrong file")
    #expect(!silent.contains { $0.contains("sound the same") })
}

@Test func aLossyFileDropsDetail() {
    let aac = compared(
        "the M4A", formatID: "aac ", storedBits: nil, effectiveBits: nil, cutoffHz: 17_000,
        sizeBytes: 4_000_000)
    let found = differences(aac, from: compared("the FLAC", sizeBytes: 30_000_000))
    #expect(
        found == [
            "The M4A stops at 17.0 kHz and the FLAC goes on to 22.05 kHz: the M4A's AAC encoder"
                + " dropped the highs to save space",
            "The M4A is AAC, a lossy format that drops detail to save space, and the FLAC keeps"
                + " every sample: at best the M4A sounds the same",
        ])
}

/// The generated fixtures, analyzed: the same noise at 44.1 kHz and upsampled to 96 kHz is
/// the same level once the spectra are matched by frequency.
@Test func anUpsampledCopyOfTheSameNoiseIsTheSameLevel() throws {
    let directory = try defaultPlaybackFixturesDirectory()
    let file = { (fixture: AnalysisFixture, name: String) in
        ComparedFile(
            name: name, openingName: name,
            result: try analyzeFile(at: try analysisFixture(fixture, in: directory)),
            sizeBytes: nil)
    }
    let found = differences(try file(.upsampled, "B"), from: try file(.fullBand, "A"))
    #expect(
        found.first?.hasPrefix("B is at 96 kHz and A at 44.1 kHz, but B's sound stops") == true)
    #expect(!found.contains { $0.contains("louder") || $0.contains("dB more") }, "\(found)")
}
