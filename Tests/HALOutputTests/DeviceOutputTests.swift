import Fixtures
import Foundation
import Playback
import Testing

@testable import HALOutput

private struct TimedOut: Error, CustomStringConvertible {
    var seen: [PlaybackEvent?]
    var description: String { "timed out; events so far: \(seen)" }
}

/// An engine playing through a `DeviceOutput` on a null device, and every update it published.
private final class Rig: @unchecked Sendable {
    let device: NullDevice
    let output: DeviceOutput
    let engine: PlaybackEngine
    private var updates: AsyncStream<PlaybackUpdate>.Iterator
    private(set) var seen: [PlaybackUpdate] = []

    init(speed: Double = 4) async throws {
        device = NullDevice(speed: speed, keepsSamples: true)
        output = try DeviceOutput(provider: device, digitalVolume: false)
        engine = PlaybackEngine(output: output)
        updates = await engine.updates().makeAsyncIterator()
    }

    deinit { output.close() }

    /// Waits for the first update from now that matches, and returns it.
    @discardableResult
    func wait(
        seconds: Double = 20, for matches: @escaping @Sendable (PlaybackUpdate) -> Bool
    ) async throws -> PlaybackUpdate {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            guard let update = await updates.next() else { break }
            seen.append(update)
            if matches(update) { return update }
        }
        throw TimedOut(seen: seen.map(\.event))
    }

    func wait(for event: PlaybackEvent) async throws {
        try await wait { $0.event == event }
    }

    var events: [PlaybackEvent] { seen.compactMap(\.event) }
}

private func album(_ rate: Int, _ bits: Int) throws -> RampAlbum {
    try rampAlbum(
        sampleRateHz: rate, bitsPerSample: bits, in: try defaultPlaybackFixturesDirectory())
}

/// Where `album`'s frames start in `samples`, and how many of them follow in order from there.
private func contiguousFrames(of album: RampAlbum, from first: Int = 0, in samples: [Int32])
    -> (start: Int, count: Int)?
{
    let (left, right) = album.frame(first)
    guard
        let start = stride(from: 0, to: samples.count - 1, by: 2).first(where: {
            samples[$0] == left && samples[$0 + 1] == right
        })
    else { return nil }
    var count = 0
    while first + count < album.totalFrames, start + 2 * count + 1 < samples.count {
        let (left, right) = album.frame(first + count)
        guard samples[start + 2 * count] == left, samples[start + 2 * count + 1] == right else {
            break
        }
        count += 1
    }
    return (start / 2, count)
}

@Test func sameFormatTracksPlayWithoutASampleOfGap() async throws {
    let album = try album(44_100, 16)
    let rig = try await Rig()
    await rig.engine.setQueue(album.tracks)
    await rig.engine.play()
    try await rig.wait(for: .finished)

    let runs = rig.device.captured
    #expect(runs.map(\.sampleRateHz) == [44_100])
    let found = try #require(contiguousFrames(of: album, in: runs[0].samples))
    #expect(found.start == 0)
    #expect(found.count == album.totalFrames)
    #expect(rig.events.filter { if case .formatChanged = $0 { true } else { false } }.count == 1)
    #expect(rig.events.contains(.trackStarted(index: 1)))
    #expect(!rig.events.contains { if case .underrun = $0 { true } else { false } })
    #expect(rig.device.openSessionCount == 0)
}

@Test func aRateChangeDrainsThenReconfiguresBetweenTracks() async throws {
    let low = try album(44_100, 16)
    let high = try album(96_000, 24)
    let rig = try await Rig()
    await rig.engine.setQueue([low.tracks[0], high.tracks[0]])
    await rig.engine.play()
    try await rig.wait(for: .trackStarted(index: 1))
    try await rig.wait(for: .finished)

    let runs = rig.device.captured
    #expect(runs.map(\.sampleRateHz) == [44_100, 96_000])
    // All of the first track before the switch, and the second from its first frame after it.
    #expect(contiguousFrames(of: low, in: runs[0].samples)?.count == low.trackFrames[0])
    let second = try #require(contiguousFrames(of: high, in: runs[1].samples))
    #expect(second.start == 0)
    #expect(second.count == high.trackFrames[0])

    let changes = rig.events.compactMap { event -> FormatChange? in
        if case .formatChanged(let change) = event { change } else { nil }
    }
    #expect(changes.count == 2)
    #expect(changes[1].from?.contains("44.1 kHz") == true)
    #expect(changes[1].to.contains("96 kHz"))
    #expect(changes[1].switchSeconds < 0.5)
}

@Test func seekingPlaysOnFromTheRequestedFrame() async throws {
    let album = try album(96_000, 24)
    let rig = try await Rig(speed: 1)
    await rig.engine.setQueue([album.tracks[0]])
    await rig.engine.play()
    try await rig.wait(for: .trackStarted(index: 0))
    await rig.engine.pause()
    await rig.engine.seek(toSeconds: 0.5)
    try await Task.sleep(nanoseconds: 50_000_000)
    let paused = try #require(await rig.engine.position())
    #expect(abs(paused - 0.5) < 0.001)
    await rig.engine.play()
    try await rig.wait(for: .finished)

    let samples = rig.device.captured[0].samples
    let after = try #require(contiguousFrames(of: album, from: 48_000, in: samples))
    #expect(after.count == album.trackFrames[0] - 48_000)
}

@Test func losingTheDevicePausesAndItsReturnLetsPlaybackResume() async throws {
    let album = try album(96_000, 24)
    let rig = try await Rig(speed: 1)
    await rig.engine.setQueue(album.tracks)
    await rig.engine.play()
    try await rig.wait(for: .trackStarted(index: 0))
    try await Task.sleep(nanoseconds: 200_000_000)

    rig.device.unplug()
    let lost = try await rig.wait { $0.event == .deviceLost }
    #expect(lost.state.status == .paused)
    #expect(rig.device.openSessionCount == 0)
    let resumeAt = try #require(await rig.engine.position())
    #expect(resumeAt > 0.1)

    rig.device.plugIn()
    let returned = try await rig.wait { $0.event == .deviceReturned }
    #expect(returned.state.device == .returned)
    #expect(rig.device.defaultsRestoredCount == 1)

    await rig.engine.play()
    try await rig.wait(for: .finished)
    let resumed = try #require(rig.device.captured.last)
    let frame = Int(resumeAt * 96_000)
    #expect(contiguousFrames(of: album, from: frame, in: resumed.samples)?.start == 0)
}

@Test func playingWithTheDeviceUnpluggedReportsItLost() async throws {
    let album = try album(44_100, 16)
    let rig = try await Rig()
    rig.device.unplug()
    await rig.engine.setQueue(album.tracks)
    await rig.engine.play()
    let lost = try await rig.wait { $0.event == .deviceLost }
    #expect(lost.state.status == .paused)
    #expect(rig.device.captured.isEmpty)
}

@Test func aFileThatWontOpenIsSkipped() async throws {
    let album = try album(44_100, 16)
    let broken = FileManager.default.temporaryDirectory
        .appendingPathComponent("broken-\(UUID().uuidString).flac")
    try Data("not audio".utf8).write(to: broken)
    defer { try? FileManager.default.removeItem(at: broken) }

    let rig = try await Rig()
    await rig.engine.setQueue([broken, album.tracks[1]])
    await rig.engine.play()
    try await rig.wait(for: .finished)
    #expect(rig.events.contains { if case .trackFailed(broken, _) = $0 { true } else { false } })
    #expect(rig.events.contains(.trackStarted(index: 1)))
    #expect(!rig.events.contains(.trackStarted(index: 0)))
}

@Test func changingTheNextTrackAfterItWasQueuedPlaysTheNewOne() async throws {
    let album = try album(44_100, 16)
    let rig = try await Rig(speed: 1)
    await rig.engine.setQueue(album.tracks)
    await rig.engine.play()
    try await rig.wait(for: .trackStarted(index: 0))
    // The whole of track 1 fits in the ring buffer, so track 2 is already queued behind it.
    try await Task.sleep(nanoseconds: 300_000_000)
    await rig.engine.setRepeat(.one)
    try await rig.wait(for: .trackStarted(index: 0))
    await rig.engine.setRepeat(.off)
    try await rig.wait(for: .finished)

    #expect(rig.events.filter { if case .trackStarted = $0 { true } else { false } }.count == 3)
    let samples = rig.device.captured[0].samples
    let last = try #require(contiguousFrames(of: album, from: album.trackFrames[0], in: samples))
    #expect(last.count == album.trackFrames[1])
}

@Test func handingOverTheNextTrackAgainKeepsTheGapClosed() async throws {
    let album = try album(44_100, 16)
    let rig = try await Rig(speed: 1)
    await rig.engine.setQueue(album.tracks)
    await rig.engine.play()
    try await rig.wait(for: .trackStarted(index: 0))
    try await Task.sleep(nanoseconds: 300_000_000)
    // Shuffle off again sends the same next track under a new item ID.
    await rig.engine.setShuffle(false)
    try await rig.wait(for: .finished)

    let found = try #require(contiguousFrames(of: album, in: rig.device.captured[0].samples))
    #expect(found.count == album.totalFrames)
    #expect(rig.events.contains(.trackStarted(index: 1)))
}
