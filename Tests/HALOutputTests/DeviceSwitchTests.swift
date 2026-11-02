import Foundation
import Testing

@testable import Fixtures
@testable import HALOutput
@testable import Playback

/// One output and engine and two null devices with different settings: a DAC without digital
/// volume, where output starts, and speakers with it at half amplitude.
private final class TwoDevices: @unchecked Sendable {
    let dac = NullDevice(name: "DAC", keepsSamples: true)
    let speakers = NullDevice(name: "Speakers", keepsSamples: true)
    let output: DeviceOutput
    let engine: PlaybackEngine
    let paths: Collected<SignalPath>
    let returns: Collected<String>
    private let updates: Collected<PlaybackUpdate>

    init() async throws {
        output = try DeviceOutput(
            DeviceChoice(provider: dac, digitalVolume: false, gain: 1, formats: nil))
        engine = PlaybackEngine(output: output)
        paths = Collected(output.signalPaths)
        returns = Collected(output.returns)
        updates = Collected(await engine.updates())
    }

    deinit { output.close() }

    var speakersChoice: DeviceChoice {
        DeviceChoice(provider: speakers, digitalVolume: true, gain: 0.5, formats: nil)
    }

    var events: [PlaybackEvent] { updates.returned.compactMap(\.event) }

    @discardableResult
    func wait(
        seconds: Double = 20, for matches: @escaping @Sendable (PlaybackUpdate) -> Bool
    ) async throws -> PlaybackUpdate {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let update = try await updates.next(within: deadline.timeIntervalSinceNow)
            if matches(update) { return update }
        }
    }

    func wait(for event: PlaybackEvent) async throws { try await wait { $0.event == event } }

    /// The first signal path from now on whose device is `name`.
    @discardableResult
    func waitForSink(_ name: String) async throws -> DeviceSink {
        let deadline = Date().addingTimeInterval(20)
        while true {
            let path = try await paths.next(within: deadline.timeIntervalSinceNow)
            if case .device(let sink) = path.sink, sink.name == name { return sink }
        }
    }
}

@Test func aFirstSeenDeviceReportsWhatItTakesForItsProfile() async throws {
    let rig = try await TwoDevices()
    let sink = try await rig.waitForSink("DAC")
    #expect(sink.uid == "DAC")
    guard case .connected(let signal) = sink.state else {
        Issue.record("expected a connected DAC, got \(sink.state)")
        return
    }
    #expect(signal.formats == NullDevice.anyRate)
    #expect(!rig.output.hasVolume)
}

@Test func switchingMidQueueCarriesOnWithTheOtherDevicesSettings() async throws {
    let album = try album(44_100, 16)
    let rig = try await TwoDevices()
    await rig.engine.setQueue(album.tracks)
    await rig.engine.play()
    try await rig.wait(for: .trackStarted(index: 0))
    try await Task.sleep(nanoseconds: 200_000_000)

    rig.output.use(rig.speakersChoice)
    let sink = try await rig.waitForSink("Speakers")
    #expect(sink.gain == 0.5)
    try await rig.wait(for: .trackStarted(index: 1))
    try await rig.wait(for: .finished)

    #expect(rig.output.hasVolume)
    #expect(rig.dac.openSessionCount == 0)
    #expect(rig.speakers.openSessionCount == 0)
    #expect(rig.dac.captured.count == 1)
    let played = try #require(rig.dac.captured.first).samples.count / 2
    #expect(played > 0 && played < album.totalFrames)
    #expect(rig.speakers.captured.map(\.sampleRateHz) == [44_100])
    // The track playing carries on; it isn't announced again.
    #expect(rig.events.filter { $0 == .trackStarted(index: 0) }.count == 1)
}

@Test func aDeviceThatWontTakeNewSettingsStopsPlaybackInsteadOfFailingTracks() async throws {
    let album = try album(44_100, 16)
    let rig = try await TwoDevices()
    await rig.engine.setQueue(album.tracks)
    await rig.engine.play()
    try await rig.wait(for: .trackStarted(index: 0))

    // As turning hog mode off reopens the DAC with other settings.
    rig.dac.refuse(.configure)
    rig.output.use(DeviceChoice(provider: rig.dac, digitalVolume: true, gain: 1, formats: nil))
    let failed = try await rig.wait { if case .failed = $0.event { true } else { false } }
    #expect(failed.event == .failed(reason: "the null device refused configure"))
    #expect(failed.state.status == .stopped)
    #expect(failed.state.currentIndex == 0)
    // Long enough for a skip to the next track to have started it.
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(!rig.events.contains { if case .trackFailed = $0 { true } else { false } })
    #expect(!rig.events.contains(.trackStarted(index: 1)))
    #expect(rig.events.filter { if case .failed = $0 { true } else { false } }.count == 1)
    #expect(rig.dac.openSessionCount == 0)
}

@Test func theLostDeviceGetsOutputBackWhenNothingPlaysElsewhere() async throws {
    let album = try album(96_000, 24)
    let rig = try await TwoDevices()
    await rig.engine.setQueue(album.tracks)
    await rig.engine.play()
    try await rig.wait(for: .trackStarted(index: 0))
    try await Task.sleep(nanoseconds: 200_000_000)
    rig.dac.unplug()
    try await rig.wait(for: .deviceLost)
    let resumeAt = try #require(await rig.engine.position())

    rig.output.use(rig.speakersChoice)
    try await rig.waitForSink("Speakers")
    rig.dac.plugIn()
    #expect(try await rig.returns.next() == "DAC")
    try await rig.waitForSink("DAC")
    #expect(!rig.output.hasVolume)

    await rig.engine.play()
    try await rig.wait(for: .finished)
    #expect(rig.speakers.captured.isEmpty)
    let resumed = try #require(rig.dac.captured.last)
    #expect(rig.dac.captured.count == 2)
    let frame = Int(resumeAt * 96_000)
    #expect(contiguousFrames(of: album, from: frame, in: resumed.samples)?.start == 0)
}

@Test func theLostDeviceComingBackLeavesOutputWhereItPlays() async throws {
    let rig = try await dacBackWhileSpeakersPlay()
    // A change of device list is handled within a control pass; give it many.
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(rig.returns.returned.isEmpty)
    #expect(rig.dac.openSessionCount == 0)
    #expect(rig.speakers.openSessionCount == 1)
}

@Test func aTrackNoReportedFormatTakesIsRefusedBeforeItPlays() async throws {
    let low = try album(44_100, 16)
    let high = try album(96_000, 24)
    let rig = try await TwoDevices()
    let only48 = DeviceFormats(
        sampleRatesHz: [44_100...44_100, 48_000...48_000],
        formats: [
            PhysicalFormat(
                formatID: linearPCMFormatID, sampleRateHz: 44_100...48_000, bitsPerChannel: 24,
                channels: 2, isFloat: false, isMixable: true)
        ])
    rig.speakers.report(only48)
    var choice = rig.speakersChoice
    choice.formats = only48
    rig.output.use(choice)
    try await rig.waitForSink("Speakers")

    // Refused when loaded, then when handed over as the next track.
    await rig.engine.setQueue([high.tracks[0], low.tracks[0], high.tracks[1], low.tracks[1]])
    await rig.engine.play()
    try await rig.wait(for: .finished)

    let refused = rig.events.compactMap { event -> (URL, String)? in
        guard case .trackFailed(let url, let reason) = event else { return nil }
        return (url, reason)
    }
    #expect(refused.map(\.0) == [high.tracks[0], high.tracks[1]])
    #expect(refused.allSatisfy { $0.1.contains("Speakers can't take 2-channel audio at 96 kHz") })
    #expect(rig.events.contains(.trackStarted(index: 1)))
    #expect(rig.events.contains(.trackStarted(index: 3)))
    #expect(rig.speakers.captured.map(\.sampleRateHz) == [44_100])
    #expect(rig.dac.captured.isEmpty)
}

/// The DAC lost while playing, the speakers chosen and playing on, and the DAC back while they
/// play.
private func dacBackWhileSpeakersPlay() async throws -> TwoDevices {
    let album = try album(44_100, 16)
    let rig = try await TwoDevices()
    await rig.engine.setQueue(album.tracks)
    await rig.engine.play()
    try await rig.wait(for: .trackStarted(index: 0))
    rig.dac.unplug()
    try await rig.wait(for: .deviceLost)
    rig.output.use(rig.speakersChoice)
    try await rig.waitForSink("Speakers")
    await rig.engine.play()
    try await rig.wait(for: .trackStarted(index: 0))
    rig.dac.plugIn()
    return rig
}

@Test func pausingOnTheOtherDeviceReturnsToTheOneThatCameBack() async throws {
    let rig = try await dacBackWhileSpeakersPlay()
    await rig.engine.pause()
    #expect(try await rig.returns.next() == "DAC")
    try await rig.waitForSink("DAC")
    await rig.engine.play()
    try await rig.wait(for: .finished)
    #expect(rig.dac.captured.count == 2)
}

@Test func theQueueEndingOnTheOtherDeviceReturnsToTheOneThatCameBack() async throws {
    let rig = try await dacBackWhileSpeakersPlay()
    try await rig.wait(for: .finished)
    #expect(try await rig.returns.next() == "DAC")
    try await rig.waitForSink("DAC")
}

@Test func stoppingOnTheOtherDeviceReturnsToTheOneThatCameBack() async throws {
    let rig = try await dacBackWhileSpeakersPlay()
    await rig.engine.stop()
    #expect(try await rig.returns.next() == "DAC")
}

/// A provider whose state reports outlive `stopWatching`, as one queued by the HAL just before it
/// would.
private final class LingeringProvider: PCMDeviceProvider, @unchecked Sendable {
    let deviceName = "Lingering"
    var deviceUID: String { deviceName }
    private let lock = NSLock()
    private var state: (@Sendable (DeviceState) -> Void)?

    func open() throws -> (any PCMDevice)? { nil }
    func isConnected() -> Bool { true }
    func watch(
        _ changed: @escaping @Sendable () -> Void,
        state: @escaping @Sendable (DeviceState) -> Void
    ) throws {
        lock.withLock { self.state = state }
        report(rateHz: 44_100)
    }
    func stopWatching() {}
    func deviceReturned() {}

    func report(rateHz: Double) {
        let format = SignalFormat(
            formatID: linearPCMFormatID, sampleRateHz: rateHz, bitsPerChannel: 32, channels: 2,
            isFloat: false)
        lock.withLock { state }?(
            .connected(
                DeviceSignal(
                    nominalSampleRateHz: rateHz, physical: format, isMixable: false,
                    hogMode: .free, volumes: [], formats: NullDevice.anyRate)))
    }
}

@Test func aStateFromTheDeviceSwitchedAwayFromIsDropped() async throws {
    let lingering = LingeringProvider()
    let speakers = NullDevice(name: "Speakers")
    let output = try DeviceOutput(
        DeviceChoice(provider: lingering, digitalVolume: false, gain: 1, formats: nil))
    defer { output.close() }
    let paths = Collected(output.signalPaths)
    func sinks(until done: (DeviceSink) -> Bool) async throws -> [DeviceSink] {
        var seen: [DeviceSink] = []
        while true {
            guard case .device(let sink) = try await paths.next().sink else { continue }
            seen.append(sink)
            if done(sink) { return seen }
        }
    }
    _ = try await sinks { $0.name == "Lingering" }
    output.use(DeviceChoice(provider: speakers, digitalVolume: false, gain: 1, formats: nil))
    _ = try await sinks { $0.name == "Speakers" }

    lingering.report(rateHz: 12_345)
    // Apart, so a path taken from the stale state would be published before the next one.
    try await Task.sleep(nanoseconds: 200_000_000)
    speakers.changeRate(to: 48_000)
    let seen = try await sinks { sink in
        guard case .connected(let signal) = sink.state else { return false }
        return signal.nominalSampleRateHz == 48_000
    }
    #expect(
        !seen.contains { sink in
            guard case .connected(let signal) = sink.state else { return false }
            return signal.nominalSampleRateHz == 12_345
        }, "\(seen)")
}
