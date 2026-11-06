import DisplayText
import Foundation
import Library
import Settings

/// What the measures suggest is wrong with a file, with one line that names its numbers. A
/// cutoff is evidence, not proof, so those two say "suspect"; the others are exact.
public struct Verdict: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable, Codable {
        case lossyOrigin, upsampled, paddedBits, fakeStereo, clipped
    }

    public var kind: Kind
    public var text: String
}

extension Verdict.Kind {
    /// The Library Health check that lists the files with this verdict (ADR 0116).
    var healthCheck: HealthCheck {
        switch self {
        case .lossyOrigin: .lossyOrigin
        case .upsampled: .upsampled
        case .paddedBits: .paddedBits
        case .fakeStereo: .fakeStereo
        case .clipped: .clipped
        }
    }
}

/// The Library Health checks `measures` earn, one per verdict, for `healthReport`.
public func healthChecks(_ measures: FileMeasures) -> [HealthCheck] {
    verdicts(measures).map(\.kind.healthCheck)
}

/// The verdicts `measures` earn, in `Verdict.Kind` order. A lossy file gets no lossy-origin
/// verdict: its cutoff is its own encoder's.
public func verdicts(_ measures: FileMeasures) -> [Verdict] {
    var found: [Verdict] = []
    let lossless = losslessFormatIDs.contains(measures.formatID)
    if let cutoff = measures.cutoffHz {
        if lossless, cutoff <= AnalysisRules.lossyCutoffHz,
            measures.sampleRateHz / 2 >= AnalysisRules.lossyMinimumNyquistHz
        {
            found.append(
                Verdict(
                    kind: .lossyOrigin,
                    text: "Cutoff at \(kilohertzText(cutoff)) kHz: suspect conversion from a"
                        + " lossy file"))
        }
        if measures.sampleRateHz > AnalysisRules.upsampledMinimumRateHz,
            cutoff <= AnalysisRules.upsampledCutoffHz
        {
            found.append(
                Verdict(
                    kind: .upsampled,
                    text: "Content stops at \(kilohertzText(cutoff)) kHz in a"
                        + " \(kilohertz(measures.sampleRateHz)) kHz file: suspect upsampled"))
        }
    }
    if let effective = measures.effectiveBits, let stored = measures.storedBits,
        effective < stored
    {
        found.append(
            Verdict(
                kind: .paddedBits,
                text: "\(effective) effective bits of \(stored) stored: padded with zero bits"))
    }
    if measures.identicalChannels == true, measures.peakDBFS != nil {
        found.append(
            Verdict(kind: .fakeStereo, text: "Left and right are identical: fake stereo"))
    }
    if measures.clippedRuns >= AnalysisRules.clippedRunsForVerdict {
        found.append(
            Verdict(
                kind: .clipped,
                text: "\(number(measures.clippedRuns)) runs of"
                    + " \(AnalysisRules.clippedRunSamples) or more samples at full scale:"
                    + " clipped"))
    }
    return found
}
