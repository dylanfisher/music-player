import Foundation
import Testing

@testable import Fixtures
@testable import HALOutput
@testable import Playback

private func sineAlbum(_ rate: Int, _ bits: Int) throws -> SineAlbum {
    try sineAlbum(
        sampleRateHz: rate, bitsPerSample: bits, in: try defaultPlaybackFixturesDirectory())
}

private let deviceRateHz = 48_000.0

/// The converter rings for a few frames where the sine starts and stops abruptly, at the album's
/// ends and after a seek; everywhere else, the join included, it holds the sine this closely.
private let edgeFrames = 200
private let tolerance = 1e-3

/// The float samples the device pulled, as stereo frames.
private func frames(_ run: NullDevice.CapturedRun) -> [(Double, Double)] {
    let floats = run.samples.map { Double(Float(bitPattern: UInt32(bitPattern: $0))) }
    return stride(from: 0, to: floats.count - 1, by: 2).map { (floats[$0], floats[$0 + 1]) }
}

/// The largest difference between `frames[range]` and the album from `seconds` at
/// `frames[start]`, frame by frame at the device's rate.
private func largestError(
    _ frames: [(Double, Double)], _ album: SineAlbum, from start: Int, atSeconds seconds: Double,
    _ range: Range<Int>
) -> Double {
    range.map { index in
        let at = seconds + Double(index - start) / deviceRateHz
        return max(
            abs(frames[index].0 - album.value(atSeconds: at, channel: 0)),
            abs(frames[index].1 - album.value(atSeconds: at, channel: 1)))
    }.max() ?? 0
}

@Test(arguments: [(44_100, 16), (96_000, 24)])
func aFloatOnlyDevicePlaysAnAlbumConvertedWithoutASeam(rate: Int, bits: Int) async throws {
    let album = try sineAlbum(rate, bits)
    let rig = try await Rig(formats: NullDevice.float48k)
    await rig.engine.setQueue(album.tracks)
    await rig.engine.play()
    try await rig.wait(for: .trackStarted(index: 1))
    try await rig.wait(for: .finished)

    let runs = rig.device.captured
    // One run: the second track carried on in the same stream.
    #expect(runs.map(\.sampleRateHz) == [deviceRateHz])
    let played = frames(runs[0])
    let audioFrames = Int((album.durationSeconds * deviceRateHz).rounded(.up))
    try #require(played.count > audioFrames)
    #expect(
        largestError(played, album, from: 0, atSeconds: 0, edgeFrames..<(audioFrames - edgeFrames))
            < tolerance)
    // Nothing repeated or added: silence follows the album's last frame.
    #expect(played[(audioFrames + edgeFrames)...].allSatisfy { $0 == (0, 0) })
    #expect(!rig.events.contains { if case .underrun = $0 { true } else { false } })

    let changes = rig.events.compactMap { event -> FormatChange? in
        if case .formatChanged(let change) = event { change } else { nil }
    }
    #expect(changes.map(\.to) == ["converted for null device: 'lpcm' 2 ch 32-bit float @ 48 kHz"])
    #expect(rig.device.openSessionCount == 0)
}

@Test func seekingAConvertedTrackLandsOnTheFilesTime() async throws {
    let album = try sineAlbum(44_100, 16)
    let rig = try await Rig(speed: 1, formats: NullDevice.float48k)
    await rig.engine.setQueue([album.tracks[0]])
    await rig.engine.play()
    try await rig.wait(for: .trackStarted(index: 0))
    try await Task.sleep(nanoseconds: 100_000_000)
    await rig.engine.pause()
    try await Task.sleep(nanoseconds: 50_000_000)
    // Stopped, the position is what the device took, counted at its rate.
    let pulled = frames(rig.device.captured[0]).count
    let stopped = try #require(await rig.engine.position())
    #expect(abs(stopped - Double(pulled) / deviceRateHz) < 1e-6)

    await rig.engine.seek(toSeconds: 0.5)
    try await Task.sleep(nanoseconds: 50_000_000)
    let paused = try #require(await rig.engine.position())
    #expect(abs(paused - 0.5) < 0.001)
    await rig.engine.play()
    try await rig.wait(for: .finished)

    // After what played before the pause, the sine carries on from half a second in.
    let played = frames(rig.device.captured[0])
    let remaining = Int(((Double(album.trackFrames[0]) / 44_100 - 0.5) * deviceRateHz).rounded(.up))
    try #require(played.count >= pulled + remaining)
    #expect(
        largestError(
            played, album, from: pulled, atSeconds: 0.5,
            (pulled + edgeFrames)..<(pulled + remaining - edgeFrames)) < tolerance)
}

@Test func aConvertedTrackShowsAsConvertedInTheSignalPath() async throws {
    let album = try sineAlbum(96_000, 24)
    let rig = try await Rig(speed: 1, formats: NullDevice.float48k)
    let paths = Collected(rig.output.signalPaths)
    await rig.engine.setQueue(album.tracks)
    await rig.engine.play()
    try await rig.wait(for: .trackStarted(index: 0))
    await rig.engine.pause()
    let float48 = SignalFormat(
        formatID: linearPCMFormatID, sampleRateHz: deviceRateHz, bitsPerChannel: 32, channels: 2,
        isFloat: true)
    while true {
        let path = try await paths.next()
        guard let track = path.track, case .connected(let device) = deviceState(path),
            device.nominalSampleRateHz == deviceRateHz
        else { continue }
        #expect(track.isConverted)
        #expect(track.decoded == float48)
        guard case .changed(let changes) = signalVerdict(path) else {
            Issue.record("a converted track judged \(signalVerdict(path))")
            return
        }
        #expect(changes.first == .converted(to: float48))
        #expect(changes.contains(.decoderResamples(fromHz: 96_000, toHz: deviceRateHz)))
        return
    }
}

private func deviceState(_ path: SignalPath) -> DeviceState {
    switch path.sink {
    case .device(let sink): sink.state
    case .renderer: .unreadable("a device output published a renderer")
    }
}
