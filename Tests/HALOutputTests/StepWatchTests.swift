import Foundation
import Testing

@testable import Fixtures
@testable import HALOutput
@testable import Playback

/// The lines a `DeviceOutput` or `StepWatch` reported, with their files.
private final class Reported: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [(line: String, file: URL?)] = []

    func diagnostics(stuckAfterSeconds: Double = 0.1) -> OutputDiagnostics {
        OutputDiagnostics(stuckAfterSeconds: stuckAfterSeconds) { line, file in
            self.lock.withLock { self.all.append((line, file)) }
        }
    }

    var lines: [(line: String, file: URL?)] { lock.withLock { all } }
}

@Test func aCallStillRunningPastTheThresholdIsReportedAndSoIsItsReturn() async throws {
    let reported = Reported()
    let watch = StepWatch(reported.diagnostics())
    let file = URL(fileURLWithPath: "/Volumes/music/track.flac")
    watch.run(.reading(file)) { Thread.sleep(forTimeInterval: 0.4) }
    let lines = reported.lines
    try #require(lines.count == 2, "\(lines)")
    #expect(lines[0].line.hasPrefix("playback is stuck: reading a track's file hasn't returned"))
    #expect(lines[1].line.hasPrefix("playback carried on: reading a track's file returned after"))
    #expect(lines.allSatisfy { $0.file == file })
}

@Test func callsThatReturnInTimeAreNotReported() async throws {
    let reported = Reported()
    let watch = StepWatch(reported.diagnostics())
    let file = URL(fileURLWithPath: "/Volumes/music/track.flac")
    let end = Date().addingTimeInterval(0.4)
    while Date() < end {
        watch.run(.reading(file)) { Thread.sleep(forTimeInterval: 0.02) }
    }
    // Long enough for a check scheduled by the last call to have fired.
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(reported.lines.isEmpty, "\(reported.lines)")
}

@Test func aDeviceCallNamesTheDeviceAndNoFile() async throws {
    let reported = Reported()
    let watch = StepWatch(reported.diagnostics())
    watch.run(.configuringDevice("ADI-2 DAC")) { Thread.sleep(forTimeInterval: 0.3) }
    let first = try #require(reported.lines.first)
    #expect(first.line.hasPrefix("playback is stuck: switching ADI-2 DAC to the track's format"))
    #expect(first.file == nil)
}

@Test func anUnderrunsLineSaysWhatTheRefillUnderWayHasDone() {
    #expect(
        underrunLine(
            seconds: 0.12, during: Refill(queuedSeconds: 5.5, wroteSeconds: 1.2, tookSeconds: 6.3))
            == "underrun: 120 ms of silence during a refill that has written 1.2 s of audio in"
            + " 6.3 s, from 5.5 s queued")
    #expect(
        underrunLine(seconds: 0.05, during: nil)
            == "underrun: 50 ms of silence while no refill was running")
}

/// A share that stops answering holds the control thread in a read; the log names it.
@Test func aReadFromAShareThatStallsIsReported() async throws {
    let track = try hiResTrack(in: try defaultPlaybackFixturesDirectory())
    let reported = Reported()
    let output = try DeviceOutput(
        DeviceChoice(provider: NullDevice(speed: 1), digitalVolume: false, gain: 1, formats: nil),
        fileLatency: FileLatency(openSeconds: 0, readSeconds: 0.3),
        diagnostics: reported.diagnostics())
    defer { output.close() }
    let engine = PlaybackEngine(output: output)
    await engine.setQueue([track])
    await engine.play()
    try await waitUntil {
        reported.lines.contains {
            $0.line.hasPrefix("playback is stuck: reading a track's file") && $0.file == track
        }
    }
}

/// A share slower than the audio it holds runs the ring buffer dry; the log says so, with the
/// refill that couldn't keep up.
@Test func anUnderrunIsLoggedWithTheRefillUnderWay() async throws {
    let track = try hiResTrack(in: try defaultPlaybackFixturesDirectory())
    let reported = Reported()
    // A block of the file holds under 2 s of audio and takes 2 s to read: the share is slower
    // than the audio.
    let output = try DeviceOutput(
        DeviceChoice(provider: NullDevice(speed: 1), digitalVolume: false, gain: 1, formats: nil),
        fileLatency: FileLatency(openSeconds: 0, readSeconds: 2),
        diagnostics: reported.diagnostics(stuckAfterSeconds: 60))
    defer { output.close() }
    let engine = PlaybackEngine(output: output)
    await engine.setQueue([track])
    await engine.play()
    let deadline = Date().addingTimeInterval(30)
    while !reported.lines.contains(where: { $0.line.hasPrefix("underrun: ") }) {
        guard Date() < deadline else { throw TimedOut(seen: "\(reported.lines)") }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let underrun = try #require(reported.lines.first { $0.line.hasPrefix("underrun: ") })
    #expect(underrun.line.contains(" during a refill that has written "), "\(underrun.line)")
    #expect(underrun.file == track)
}
