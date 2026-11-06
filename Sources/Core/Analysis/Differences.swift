import DisplayText
import Foundation
import Library
import Playback

/// One file of a comparison (ADR 0120): what the sentences call it, what it measured, and its
/// size where the index has it.
public struct ComparedFile: Sendable {
    /// The file's name inside a sentence, such as "the FLAC" or a title.
    public var name: String
    /// The same at the start of one, such as "The FLAC".
    public var openingName: String
    public var result: AnalysisResult
    public var sizeBytes: Int?

    public init(name: String, openingName: String, result: AnalysisResult, sizeBytes: Int?) {
        self.name = name
        self.openingName = openingName
        self.result = result
        self.sizeBytes = sizeBytes
    }

    var measures: FileMeasures { result.measures }
    var lossless: Bool { losslessFormatIDs.contains(measures.formatID) }
    /// Where its content stops: its cutoff, or its Nyquist frequency.
    var topHz: Double { measures.cutoffHz ?? measures.sampleRateHz / 2 }
}

/// How `file` differs from `first`, a sentence each, for someone who doesn't read spectra:
/// what differs, by how much, and what it usually means, hedged where a measure only
/// suggests it. The ways they'd sound different come first, then how they're stored; when
/// none of the first kind passes its threshold, a last sentence says they sound the same as
/// far as the measures tell. Built from the measures and the average spectra alone.
public func differences(_ file: ComparedFile, from first: ComparedFile) -> [String] {
    let pair = [first, file]
    // The ways they'd sound different, and whether any of them is one.
    var heard: [String] = []
    var sounds = false
    func add(_ sentence: String?, isSound: Bool = true) {
        guard let sentence else { return }
        heard.append(sentence)
        sounds = sounds || isSound
    }
    add(cutoffDifference(pair))
    let spectra = SpectrumComparison(pair)
    add(spectra?.levelSentence)
    add(dynamicRangeDifference(pair))
    add(truePeakDifference(pair))
    add(clippingDifference(pair))
    for band in spectra?.bandSentences ?? [] { add(band.text, isSound: band.isSound) }
    add(lengthDifference(pair))
    let stored = [
        rateDifference(pair), bitsDifference(pair), formatDifference(pair),
        sizeDifference(pair),
    ].compactMap { $0 }
    let same =
        sounds
        ? []
        : [
            "\(file.openingName) and \(first.name) sound the same as far as these measures can"
                + " tell: only comparing their samples could prove the audio identical"
        ]
    return heard + stored + same
}

/// "So Many Questions" as "So Many Questions's", "the FLAC" as "the FLAC's".
private func possessive(_ name: String) -> String { name + "'s" }

private func codec(_ file: ComparedFile) -> String { codecName(file.measures) }

/// The file whose `value` is the higher first, then the other; nil when they're equal.
private func ordered<Value: Comparable>(
    _ pair: [ComparedFile], by value: (ComparedFile) -> Value
) -> (higher: ComparedFile, lower: ComparedFile)? {
    let (a, b) = (pair[0], pair[1])
    if value(a) == value(b) { return nil }
    return value(a) > value(b) ? (a, b) : (b, a)
}

/// The one of `pair` that `test` holds for, and the other; nil when it holds for both or
/// neither.
private func only(
    _ pair: [ComparedFile], _ test: (ComparedFile) -> Bool
) -> (this: ComparedFile, other: ComparedFile)? {
    switch (test(pair[0]), test(pair[1])) {
    case (true, false): (pair[0], pair[1])
    case (false, true): (pair[1], pair[0])
    default: nil
    }
}

private func cutoffDifference(_ pair: [ComparedFile]) -> String? {
    guard let (high, low) = ordered(pair, by: \.topHz), let cutoff = low.measures.cutoffHz,
        high.topHz - cutoff >= AnalysisRules.differentCutoffHz
    else { return nil }
    let reach =
        high.measures.cutoffHz.map(kilohertzLabel)
        ?? "\(kilohertz(high.measures.sampleRateHz / 2)) kHz"
    let kinds = verdicts(low.measures).map(\.kind)
    let meaning =
        if kinds.contains(.lossyOrigin) {
            "\(low.name) was probably made from an MP3 or AAC file"
        } else if kinds.contains(.upsampled) {
            "\(low.name) was probably made from a copy at a lower rate"
        } else if !low.lossless {
            "\(possessive(low.name)) \(codec(low)) encoder dropped the highs to save space"
        } else {
            "\(possessive(low.name)) highs were probably filtered off, as in a resampled copy"
        }
    return "\(low.openingName) stops at \(kilohertzLabel(cutoff)) and \(high.name) goes on to"
        + " \(reach): \(meaning)"
}

private func dynamicRangeDifference(_ pair: [ComparedFile]) -> String? {
    guard let a = pair[0].measures.dynamicRange, let b = pair[1].measures.dynamicRange,
        abs(a - b) >= AnalysisRules.differentDynamicRange,
        let (wide, narrow) = ordered(pair, by: { $0.measures.dynamicRange ?? 0 })
    else { return nil }
    return "\(possessive(narrow.openingName)) DR is \(narrow.measures.dynamicRange ?? 0) against"
        + " \(possessive(wide.name)) \(wide.measures.dynamicRange ?? 0): \(narrow.name) is more"
        + " compressed, its loud and quiet moments closer together, typical of a loud remaster"
}

private func truePeakDifference(_ pair: [ComparedFile]) -> String? {
    guard
        let (over, other) = only(
            pair,
            {
                ($0.measures.truePeakDBTP ?? -.infinity) > AnalysisRules.overFullScaleDBTP
            }), let peak = over.measures.truePeakDBTP
    else { return nil }
    return "\(over.openingName) peaks at \(truePeakText(peak)) between samples, over full"
        + " scale, and \(other.name) stays under: \(over.name) may distort slightly in some"
        + " players and converters"
}

private func clippingDifference(_ pair: [ComparedFile]) -> String? {
    guard
        let (clipped, other) = only(
            pair,
            {
                $0.measures.clippedRuns >= AnalysisRules.clippedRunsForVerdict
            })
    else { return nil }
    return "\(clipped.openingName) has \(number(clipped.measures.clippedRuns)) clipped runs and"
        + " \(other.name) \(number(other.measures.clippedRuns)):"
        + " \(possessive(clipped.name)) peaks were probably cut off to make it louder"
}

private func lengthDifference(_ pair: [ComparedFile]) -> String? {
    guard let (long, short) = ordered(pair, by: \.measures.durationSeconds) else { return nil }
    let seconds = long.measures.durationSeconds - short.measures.durationSeconds
    guard seconds >= AnalysisRules.differentLengthSeconds else { return nil }
    let amount = seconds < 60 ? "\(Int(seconds.rounded())) seconds" : clock(seconds)
    return "\(long.openingName) is \(amount) longer than \(short.name): probably a different"
        + " edit, a longer fade or more silence at the ends"
}

private func rateDifference(_ pair: [ComparedFile]) -> String? {
    guard let (high, low) = ordered(pair, by: \.measures.sampleRateHz) else { return nil }
    let lowNyquist = low.measures.sampleRateHz / 2
    let rates =
        "\(high.openingName) is at \(kilohertz(high.measures.sampleRateHz)) kHz and"
        + " \(low.name) at \(kilohertz(low.measures.sampleRateHz)) kHz"
    if let cutoff = high.measures.cutoffHz,
        cutoff <= lowNyquist + AnalysisRules.differentCutoffHz
    {
        return rates + ", but \(possessive(high.name)) sound stops at"
            + " \(kilohertzLabel(cutoff)): \(high.name) was probably upsampled, with nothing"
            + " gained"
    }
    return rates + ": the higher rate adds only sound above \(kilohertz(lowNyquist)) kHz,"
        + " beyond human hearing"
}

/// The level each bit of depth adds: 20 log10(2).
private let decibelsPerBit = 20 * log10(2.0)

private func bitsDifference(_ pair: [ComparedFile]) -> String? {
    let (a, b) = (pair[0].measures, pair[1].measures)
    guard let effectiveA = a.effectiveBits, let effectiveB = b.effectiveBits,
        let storedA = a.storedBits, let storedB = b.storedBits
    else { return nil }
    if effectiveA == effectiveB {
        guard let (padded, other) = ordered(pair, by: { $0.measures.storedBits ?? 0 }) else {
            return nil
        }
        return "\(padded.openingName) is \(bitDepth(max(storedA, storedB))) but holds"
            + " \(effectiveA) bits of detail: no more detail than \(other.name)"
    }
    guard let (more, fewer) = ordered(pair, by: { $0.measures.effectiveBits ?? 0 }) else {
        return nil
    }
    let fewerBits = min(effectiveA, effectiveB)
    let moreBits = max(effectiveA, effectiveB)
    if let stored = fewer.measures.storedBits, fewerBits < stored {
        return "\(fewer.openingName) is \(bitDepth(stored)) but holds \(fewerBits) bits of"
            + " detail, and \(more.name) \(moreBits): \(fewer.name) was probably made from a"
            + " \(fewerBits)-bit copy"
    }
    let quietest = Int((decibelsPerBit * Double(fewerBits)).rounded())
    return "\(more.openingName) holds \(moreBits) bits of detail and \(fewer.name) \(fewerBits):"
        + " the extra bits only hold sound more than \(quietest) dB under full scale, too quiet"
        + " to hear at a normal volume"
}

private func formatDifference(_ pair: [ComparedFile]) -> String? {
    let (first, file) = (pair[0], pair[1])
    guard codec(first) != codec(file) else { return nil }
    let kept = "so the format alone changes nothing you hear"
    if let (lossy, other) = only(pair, { !$0.lossless }) {
        return "\(lossy.openingName) is \(codec(lossy)), a lossy format that drops detail to"
            + " save space, and \(other.name) keeps every sample: at best \(lossy.name) sounds"
            + " the same"
    }
    if !first.lossless {
        return "\(file.openingName) is \(codec(file)) and \(first.name) \(codec(first)): both"
            + " drop detail to save space, each in its own way"
    }
    if let (pcm, compressed) = only(pair, { $0.measures.formatID == linearPCMFormatID }) {
        return "\(compressed.openingName) is compressed without loss and \(pcm.name) is"
            + " uncompressed: either way every sample is kept, \(kept)"
    }
    return "\(file.openingName) is \(codec(file)) and \(first.name) \(codec(first)): both keep"
        + " every sample, \(kept)"
}

private func sizeDifference(_ pair: [ComparedFile]) -> String? {
    let (first, file) = (pair[0], pair[1])
    guard first.lossless, file.lossless, let a = first.sizeBytes, let b = file.sizeBytes,
        Double(abs(a - b)) >= AnalysisRules.differentSizeShare * Double(max(a, b))
    else { return nil }
    return "\(file.openingName) is \(fileSizeText(b)) and \(first.name) \(fileSizeText(a)):"
        + " a lossless file's size follows its format, bits and rate, not how it sounds"
}

/// The two files' average spectra compared by frequency, not row, as their rates can differ:
/// the overall level and the bands, each from the power summed over its frequencies, up to
/// where the one that stops lower stops.
private struct SpectrumComparison {
    var pair: [ComparedFile]
    /// The top of what both hold: the lower Nyquist, or a cutoff less the half span its fall
    /// is measured over.
    var ceilingHz: Double
    /// The later file's level over the first's, in dB.
    var levelDB: Double
    /// The same over the midrange, which the bands are measured against, so a louder file
    /// isn't read as having more bass.
    var midrangeDB: Double

    /// Nil when either file is silent, as a silent file has no level to compare.
    init?(_ pair: [ComparedFile]) {
        guard pair.allSatisfy({ $0.measures.peakDBFS != nil }) else { return nil }
        self.pair = pair
        ceilingHz =
            pair.map { file in
                file.measures.cutoffHz.map { $0 - AnalysisRules.cutoffSpanHz / 2 }
                    ?? file.measures.sampleRateHz / 2
            }.min() ?? 0
        (levelDB, midrangeDB) = (0, 0)
        let midrange = AnalysisRules.midrangeHz
        guard let level = difference(from: AnalysisRules.levelFromHz),
            let middle = difference(from: midrange.lowerBound, to: midrange.upperBound)
        else { return nil }
        (levelDB, midrangeDB) = (level, middle)
    }

    /// The later file's power over the first's from `low` up to `high` or the ceiling, in dB;
    /// nil when the ceiling is under `low`.
    func difference(from low: Double, to high: Double = .infinity) -> Double? {
        let top = min(high, ceilingHz)
        guard top > low else { return nil }
        let powers = pair.map { power(of: $0.result.spectrogram, from: low, to: top) }
        return 10 * log10(powers[1] / powers[0])
    }

    var levelSentence: String? {
        guard abs(levelDB) >= AnalysisRules.differentLevelDB else { return nil }
        let (loud, quiet) = levelDB > 0 ? (pair[1], pair[0]) : (pair[0], pair[1])
        return "\(loud.openingName) is about \(Int(abs(levelDB).rounded())) dB louder overall"
            + " than \(quiet.name): turn it down that much to compare them fairly, as louder"
            + " tends to sound better"
    }

    /// The bass, the treble and the top's sentences, each where the band differs from the
    /// midrange by enough; the top's isn't one of how they sound when it's the dither
    /// a 16-bit copy gets.
    var bandSentences: [(text: String, isSound: Bool)] {
        var found: [(text: String, isSound: Bool)] = []
        for (band, name) in [
            (AnalysisRules.levelFromHz...AnalysisRules.midrangeHz.lowerBound, "bass"),
            (AnalysisRules.midrangeHz.upperBound...AnalysisRules.topBandFromHz, "treble"),
        ] {
            guard let (more, less, decibels) = tilt(from: band.lowerBound, to: band.upperBound)
            else { continue }
            found.append(
                (
                    "\(more.openingName) has about \(decibels) dB more \(name) than"
                        + " \(less.name), measured against their midrange: a different"
                        + " EQ, as remasters often have", true
                ))
        }
        let top = AnalysisRules.topBandFromHz
        if let (more, less, decibels) = tilt(from: top) {
            let above =
                "\(more.openingName) has about \(decibels) dB more above \(kilohertz(top))"
                + " kHz than \(less.name)"
            if more.lossless, less.lossless, let bits = more.measures.effectiveBits,
                bits < less.measures.effectiveBits ?? 0
            {
                found.append(
                    (
                        above + ", where music has little: probably noise-shaped dither, added"
                            + " when it was made \(bitDepth(bits))", false
                    ))
            } else {
                found.append(
                    (
                        above + ": a little more air, or more noise, as music has little up there",
                        true
                    ))
            }
        }
        return found
    }

    /// The file with more in the band than the midrange accounts for, the other, and by
    /// how many whole dB; nil under `AnalysisRules.differentBandDB`.
    private func tilt(from low: Double, to high: Double = .infinity) -> (
        more: ComparedFile, less: ComparedFile, decibels: Int
    )? {
        guard let band = difference(from: low, to: high) else { return nil }
        let tilt = band - midrangeDB
        guard abs(tilt) >= AnalysisRules.differentBandDB else { return nil }
        let (more, less) = tilt > 0 ? (pair[1], pair[0]) : (pair[0], pair[1])
        return (more, less, Int(abs(tilt).rounded()))
    }
}

/// The power of `spectrogram`'s average spectrum from `low` to `high` Hz, each row counted
/// for the share of it inside. Every row holds the same number of bins, so the sums of two
/// files at different rates compare.
private func power(of spectrogram: Spectrogram, from low: Double, to high: Double) -> Double {
    let rowHz = spectrogram.nyquistHz / Double(Spectrogram.rows)
    var sum = 0.0
    for row in 0..<Spectrogram.rows {
        let bottom = Double(row) * rowHz
        let inside = min(bottom + rowHz, high) - max(bottom, low)
        if inside > 0 {
            sum += pow(10, Double(spectrogram.averageDB[row]) / 10) * inside / rowHz
        }
    }
    return sum
}
