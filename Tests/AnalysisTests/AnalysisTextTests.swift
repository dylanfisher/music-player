import Foundation
import Library
import Testing

@testable import Analysis

private let padded = FileMeasures(
    formatID: "flac", sampleRateHz: 96_000, storedBits: 24, channels: 2, isFloat: false,
    durationSeconds: 300, cutoffHz: 22_050, cutoffSteepnessDBPerKHz: 150.4, effectiveBits: 16,
    identicalChannels: false, peakDBFS: -0.14, truePeakDBTP: 0.42, clippedRuns: 3,
    dynamicRange: 7)

private let lossy = FileMeasures(
    formatID: "aac ", sampleRateHz: 44_100, storedBits: nil, channels: 1, isFloat: true,
    durationSeconds: 61, cutoffHz: nil, cutoffSteepnessDBPerKHz: nil, effectiveBits: nil,
    identicalChannels: nil, peakDBFS: -3, truePeakDBTP: -2.95, clippedRuns: 0, dynamicRange: 12)

@Test func theFormatLineNamesCodecRateBitsChannelsAndLength() {
    #expect(formatLine(padded) == "FLAC · 96 kHz · 24-bit stored, 16 effective · stereo · 5:00")
    #expect(formatLine(lossy) == "AAC · 44.1 kHz · mono · 1:01")
    var float = lossy
    float.formatID = "lpcm"
    float.storedBits = 32
    #expect(formatLine(float) == "PCM · 44.1 kHz · 32-bit float · mono · 1:01")
}

@Test func theMeasuresReadAsNamesAndValues() {
    let items = Dictionary(uniqueKeysWithValues: measureItems(padded).map { ($0.name, $0.value) })
    #expect(items["Cutoff"] == "22.1 kHz, falling 150 dB per kHz")
    #expect(items["Effective bits"] == "16 of 24")
    #expect(items["Left and right"] == "differ")
    #expect(items["Peak"] == "-0.1 dBFS")
    #expect(items["True peak"] == "+0.4 dBTP")
    #expect(items["Clipped runs"] == "3 of 3 or more samples")
    #expect(items["Dynamic range"] == "DR7")
    let none = Dictionary(uniqueKeysWithValues: measureItems(lossy).map { ($0.name, $0.value) })
    #expect(none["Cutoff"] == "none: content reaches 22.05 kHz")
    #expect(none["Effective bits"] == "not counted for float or lossy samples")
    #expect(none["Left and right"] == "mono")
}

@Test func theReportListsEachFileWithItsVerdicts() {
    let report = analysisReport([("/a.flac", padded), ("/b.m4a", lossy)])
    let blocks = report.components(separatedBy: "\n\n")
    #expect(blocks.count == 2)
    #expect(blocks[0].hasPrefix("/a.flac\n  FLAC · 96 kHz"))
    #expect(blocks[0].contains("\n  Effective bits: 16 of 24\n"))
    #expect(blocks[0].hasSuffix("\n  16 effective bits of 24 stored: padded with zero bits"))
    #expect(blocks[0].contains("suspect upsampled"))
    #expect(blocks[1].hasSuffix("\n  \(noVerdictText)"))
}

@Test func theJSONHasEveryKeyAndNullsForWhatDoesntApply() throws {
    let text = try analysisJSON([("/b.m4a", lossy), ("/a.flac", padded)])
    let objects = try #require(
        try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
    #expect(objects.count == 2)
    #expect(Set(objects[0].keys) == Set(objects[1].keys))
    #expect(objects[0]["cutoffHz"] is NSNull)
    #expect(objects[0]["path"] as? String == "/b.m4a")
    #expect((objects[0]["verdicts"] as? [Any])?.isEmpty == true)
    let verdicts = try #require(objects[1]["verdicts"] as? [[String: String]])
    #expect(verdicts.map { $0["kind"] } == ["upsampled", "paddedBits"])
    #expect(text.contains("\"path\":\"/a.flac\""))
}
