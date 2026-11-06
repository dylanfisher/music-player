import DisplayText
import Foundation
import Library
import Playback

/// "FLAC · 96 kHz · 24-bit stored, 16 effective · stereo · 5:00": the codec, the rate, the
/// stored and effective bits where there are any, the channels and the length.
public func formatLine(_ measures: FileMeasures) -> String {
    let format = SignalFormat(
        formatID: measures.formatID, sampleRateHz: measures.sampleRateHz,
        bitsPerChannel: measures.storedBits.map(UInt32.init), channels: UInt32(measures.channels),
        isFloat: measures.isFloat)
    var parts = [format.codecName, "\(kilohertz(measures.sampleRateHz)) kHz"]
    if let stored = measures.storedBits {
        let effective = measures.effectiveBits.map { ", \($0) effective" } ?? ""
        parts.append(
            losslessFormatIDs.contains(measures.formatID) && measures.isFloat
                ? depthText(bits: UInt32(stored), isFloat: true)
                : "\(bitDepth(stored)) stored\(effective)")
    }
    parts.append(channelsText(measures.channels))
    parts.append(clock(measures.durationSeconds))
    return parts.joined(separator: " · ")
}

/// Each measure's name and value, as the Spectrum window lists them and the command line
/// prints them.
public func measureItems(_ measures: FileMeasures) -> [(name: String, value: String)] {
    [
        (
            "Cutoff",
            measures.cutoffHz.map { cutoff in
                "\(kilohertzText(cutoff)) kHz"
                    + (measures.cutoffSteepnessDBPerKHz.map {
                        String(format: ", falling %.0f dB per kHz", $0)
                    } ?? "")
            } ?? "none: content reaches \(kilohertz(measures.sampleRateHz / 2)) kHz"
        ),
        (
            "Effective bits",
            measures.effectiveBits.map { "\($0) of \(measures.storedBits ?? $0)" }
                ?? (measures.isFloat ? "not counted for float or lossy samples" : "silent")
        ),
        (
            "Left and right",
            measures.identicalChannels.map { $0 ? "identical" : "differ" }
                ?? channelsText(measures.channels)
        ),
        ("Peak", measures.peakDBFS.map { String(format: "%.1f dBFS", $0) } ?? "silent"),
        ("True peak", measures.truePeakDBTP.map { String(format: "%+.1f dBTP", $0) } ?? "silent"),
        (
            "Clipped runs",
            number(measures.clippedRuns) + " of \(AnalysisRules.clippedRunSamples) or more samples"
        ),
        ("Dynamic range", measures.dynamicRange.map { "DR\($0)" } ?? "silent"),
    ]
}

/// The line the window and the command line show when no verdict applies.
public let noVerdictText = "No problems found"

/// What `music-player analyze` prints for each file: its path, format line, measures and
/// verdicts.
public func analysisReport(_ files: [(path: String, measures: FileMeasures)]) -> String {
    files.map { file in
        let verdictLines = verdicts(file.measures).map(\.text)
        return
            ([file.path, "  " + formatLine(file.measures)]
            + measureItems(file.measures).map { "  \($0.name): \($0.value)" }
            + (verdictLines.isEmpty ? [noVerdictText] : verdictLines).map { "  " + $0 })
            .joined(separator: "\n")
    }.joined(separator: "\n\n")
}

/// The same as JSON: an array with an object per file, keys sorted, every key always present,
/// a measure that doesn't apply as null.
public func analysisJSON(_ files: [(path: String, measures: FileMeasures)]) throws -> String {
    let objects = files.map { file -> [String: Any] in
        let measures = file.measures
        let fields: [String: Any?] = [
            "path": file.path, "formatID": measures.formatID,
            "sampleRateHz": measures.sampleRateHz, "storedBits": measures.storedBits,
            "channels": measures.channels, "isFloat": measures.isFloat,
            "durationSeconds": measures.durationSeconds, "cutoffHz": measures.cutoffHz,
            "cutoffSteepnessDBPerKHz": measures.cutoffSteepnessDBPerKHz,
            "effectiveBits": measures.effectiveBits,
            "identicalChannels": measures.identicalChannels, "peakDBFS": measures.peakDBFS,
            "truePeakDBTP": measures.truePeakDBTP, "clippedRuns": measures.clippedRuns,
            "dynamicRange": measures.dynamicRange,
            "verdicts": verdicts(measures).map { ["kind": $0.kind.rawValue, "text": $0.text] },
        ]
        return fields.mapValues { $0 ?? NSNull() }
    }
    let data = try JSONSerialization.data(
        withJSONObject: objects, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}
