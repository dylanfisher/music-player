import Foundation
import Library
import Testing

@testable import Analysis
@testable import Spectrum

/// A result whose spectrogram has 10 columns, each row's cells at `level(row)` dB, and whose
/// measures are a clean 16-bit FLAC's at `rateHz`.
private func result(rateHz: Double, cutoffHz: Double? = nil, level: (Int) -> Double = { _ in -60 })
    -> AnalysisResult
{
    let cells = (0..<10).flatMap { _ in
        (0..<Spectrogram.rows).map { Spectrogram.cell(level($0)) }
    }
    return AnalysisResult(
        measures: FileMeasures(
            formatID: "flac", sampleRateHz: rateHz, storedBits: 16, channels: 2, isFloat: false,
            durationSeconds: 100, cutoffHz: cutoffHz,
            cutoffSteepnessDBPerKHz: cutoffHz.map { _ in 150 },
            effectiveBits: 16, identicalChannels: false, peakDBFS: -1, truePeakDBTP: -0.5,
            clippedRuns: 0, dynamicRange: 9),
        spectrogram: Spectrogram(
            columns: 10, cells: cells,
            averageDB: (0..<Spectrogram.rows).map { Float(level($0)) }, nyquistHz: rateHz / 2,
            durationSeconds: 100))
}

/// A file titled `title` at "/<title, lowercased>.<type, lowercased>".
private func file(
    _ title: String, album: String? = nil, sizeBytes: Int? = nil, type: String = "FLAC"
) -> SpectrumModel.File {
    SpectrumModel.File(
        path: "/\(title.lowercased()).\(type.lowercased())", title: title, album: album,
        sizeBytes: sizeBytes, fileType: type)
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private(set) var most = 0
    private(set) var cancelled = 0

    func begin() {
        lock.withLock {
            running += 1
            most = max(most, running)
        }
    }

    func end(cancelled wasCancelled: Bool) {
        lock.withLock {
            running -= 1
            if wasCancelled { cancelled += 1 }
        }
    }

    var cancelledCount: Int { lock.withLock { cancelled } }
    var mostAtOnce: Int { lock.withLock { most } }
}

private struct Unreadable: Error, CustomStringConvertible {
    var description: String { "the file is damaged" }
}

@MainActor @Test func eachFileShowsItsProgressThenItsResult() async {
    let model = SpectrumModel(files: [file("A"), file("B"), file("C")])
    var seen: [String] = []
    model.changed = { seen.append(model.status(0)) }
    model.start { path, progress in
        progress(0.5)
        try await Task.sleep(nanoseconds: 20_000_000)
        if path == "/c.flac" { throw Unreadable() }
        return result(rateHz: path == "/a.flac" ? 44_100 : 96_000)
    }
    await model.finished()
    #expect(seen.contains("Analyzing… 0%"))
    #expect(seen.contains("Analyzing… 50%"))
    #expect(model.status(0) == "FLAC · 44.1 kHz · 16-bit stored, 16 effective · stereo · 1:40")
    #expect(model.status(2) == "Couldn't analyze: the file is damaged")
    #expect(model.results.map { $0 != nil } == [true, true, false])
    // The axis reaches the highest Nyquist, and its lines stop under it.
    #expect(model.topHz == 48_000)
    #expect(model.referenceLines == [16_000, 19_000, 20_000, 22_050, 24_000])
    #expect(model.legend(1) == "B — FLAC · 96 kHz · 16-bit stored, 16 effective · stereo · 1:40")
    #expect(model.legend(2) == "C")
    #expect(model.verdictLines(0) == [noVerdictText])
    #expect(model.verdictLines(2).isEmpty)
}

@MainActor @Test func atMostTwoFilesAreAnalyzedAtOnce() async {
    let files = (0..<AnalysisRules.comparedFiles).map { file("\($0)") }
    let model = SpectrumModel(files: files)
    let calls = Calls()
    model.start { _, _ in
        calls.begin()
        try? await Task.sleep(nanoseconds: 10_000_000)
        calls.end(cancelled: false)
        return result(rateHz: 44_100)
    }
    await model.finished()
    #expect(calls.mostAtOnce == SpectrumModel.filesAtOnce)
    #expect(model.results.allSatisfy { $0 != nil })
}

@MainActor @Test func closingCancelsTheFilesStillAnalyzed() async {
    let model = SpectrumModel(files: [file("A"), file("B"), file("C")])
    let calls = Calls()
    model.start { _, _ in
        calls.begin()
        do {
            try await Task.sleep(nanoseconds: 10_000_000_000)
        } catch {
            calls.end(cancelled: true)
            throw error
        }
        calls.end(cancelled: false)
        return result(rateHz: 44_100)
    }
    while calls.mostAtOnce < 2 { await Task.yield() }
    model.cancel()
    await model.finished()
    #expect(calls.cancelledCount == 2)
    // A cancelled file isn't a failure, and the third never started.
    #expect(model.status(0) == "Analyzing… 0%")
    #expect(model.status(2) == "Waiting to start")
}

@MainActor @Test func thePointerReadsTimeFrequencyAndLevel() async {
    let model = SpectrumModel(files: [file("A"), file("B")])
    model.start { path, _ in
        path == "/a.flac"
            ? result(rateHz: 44_100, level: { $0 < 256 ? -40 : -120 })
            : result(rateHz: 96_000)
    }
    await model.finished()
    // The axis is the 96 kHz file's: halfway up is 24 kHz, over the first file's Nyquist.
    #expect(model.readout(file: 0, x: 0.5, y: 0.5) == "0:50 · 24.0 kHz · over this file's Nyquist")
    #expect(model.readout(file: 0, x: 0.1, y: 0.1) == "0:10 · 4.8 kHz · -40 dB")
    #expect(model.readout(file: 0, x: 0, y: 0.4) == "0:00 · 19.2 kHz · -120 dB")
    #expect(model.readout(file: 1, x: 1, y: 0.5) == "1:40 · 24.0 kHz · -60 dB")
    #expect(model.readout(file: 1, x: 1.2, y: 0.5) == nil)
    #expect(model.averageReadout(y: 0.1) == "4.8 kHz · A -40 dB · B -60 dB")
    #expect(model.averageReadout(y: 0.5) == "24.0 kHz · B -60 dB")
}

@Test func theFloorOfTheScaleReadsAsUnderIt() {
    #expect(decibelsText(-150) == "under -150 dB")
    #expect(decibelsText(-63.4) == "-63 dB")
}

@MainActor @Test func theHeaderNamesTheAlbumAndEndsWithTheSize() async {
    let model = SpectrumModel(files: [
        file("So Many Questions", album: "Album", sizeBytes: 44_812_345), file("B"),
    ])
    model.start { _, _ in result(rateHz: 44_100) }
    await model.finished()
    #expect(model.heading(0) == "So Many Questions — Album")
    #expect(model.heading(1) == "B")
    #expect(
        model.status(0)
            == "FLAC · 44.1 kHz · 16-bit stored, 16 effective · stereo · 1:40 · 44.8 MB")
    // A file the index doesn't have has no size to show.
    #expect(model.status(1) == "FLAC · 44.1 kHz · 16-bit stored, 16 effective · stereo · 1:40")
}

@Test func aFileTheIndexDoesntHaveIsNamedByItsFile() {
    let file = SpectrumModel.File(path: "/Music/01 Intro.flac", row: nil)
    #expect(file.title == "01 Intro")
    #expect(file.album == nil)
    #expect(file.sizeBytes == nil)
    #expect(file.fileType == "FLAC")
}

@MainActor @Test func filesOfOneTitleAreNamedByTheirTypeThenByTheirPlace() {
    let model = SpectrumModel(files: [
        file("Song", type: "WAV"), file("Song"), file("Other"), file("Song"),
    ])
    #expect(model.names == ["the WAV", "file 2", "Other", "file 4"])
    #expect(model.heading(0) == "Song (WAV)")
    #expect(model.heading(1) == "Song")
}
