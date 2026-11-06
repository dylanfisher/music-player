import AppKit
import Foundation
import Testing

@testable import NowPlaying
@testable import Playback

private struct Refused: PlaybackFailure {
    var description: String { "DeviceOutputError.cannotPlayDSD(ADI-2 DAC, noHogMode)" }
    var userMessage: String { "DoP needs exclusive access, and hog mode is off for this device" }
}

private let track = URL(fileURLWithPath: "/m/Kind of Blue/So What.dsf", isDirectory: false)

private let shown = ShownProblem(
    problem: PlaybackProblem(Refused()), track: track, entry: 0, trackFormat: "DSD64",
    headline: "Couldn't play So What.dsf: DoP needs exclusive access, and hog mode is off for"
        + " this device")

private let devicePath = SignalPath(
    track: nil,
    sink: .device(
        DeviceSink(
            name: "ADI-2 DAC", uid: "ADI-2",
            state: .connected(
                DeviceSignal(
                    nominalSampleRateHz: 44_100,
                    physical: SignalFormat(
                        formatID: "lpcm", sampleRateHz: 44_100, bitsPerChannel: 32, channels: 2,
                        isFloat: false),
                    isMixable: true, hogMode: .free, volumes: [],
                    formats: DeviceFormats(sampleRatesHz: [], formats: []))),
            gain: 1)))

@Test func theReportHasTheTrackTheDeviceHogModeTheErrorAndTheLog() {
    var report = ProblemReport(shown, path: devicePath, hogMode: false)
    report.logLines = ["10:41:07.215 HALOutput error: refused DSD64 on ADI-2 DAC"]
    let lines = report.text.components(separatedBy: "\n")
    #expect(lines.first == shown.headline)
    #expect(lines.contains("Track: /m/Kind of Blue/So What.dsf"))
    #expect(lines.contains("Format: DSD64"))
    #expect(lines.contains("Output: ADI-2 DAC: 44.1 kHz · 32-bit (Shared with other apps)"))
    #expect(lines.contains("Hog mode: off for this device"))
    #expect(lines.contains("Error: DeviceOutputError.cannotPlayDSD(ADI-2 DAC, noHogMode)"))
    #expect(lines.last == "10:41:07.215 HALOutput error: refused DSD64 on ADI-2 DAC")
    // A renderer has no hog mode, and no output says so.
    let renderer = ProblemReport(shown, path: nil, hogMode: nil).text
    #expect(!renderer.contains("Hog mode") && renderer.contains("Output: No output device"))
}

@MainActor @Test func theWindowShowsTheReportReadsTheLogAndCopiesIt() async throws {
    let window = PlaybackProblemWindow()
    window.readLog = { ["10:41:07.215 Playback error: /m/So What.dsf: refused"] }
    window.pasteboard = NSPasteboard(name: NSPasteboard.Name("problem-\(UUID().uuidString)"))
    defer { window.pasteboard.releaseGlobally() }
    window.show(ProblemReport(shown, path: devicePath, hogMode: false))
    #expect(window.headline.stringValue == shown.headline)
    #expect(window.details.string.hasSuffix("Reading the log…"))
    for _ in 0..<200 where window.report?.logLines == nil {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    #expect(window.details.string.hasSuffix("10:41:07.215 Playback error: /m/So What.dsf: refused"))
    window.copyButton.performClick(nil)
    #expect(window.pasteboard.string(forType: .string) == window.details.string)
    window.window.close()
}
