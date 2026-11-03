import Foundation
import Testing

@testable import Fixtures
@testable import HALOutput
@testable import Log
@testable import Playback

struct TimedOut: Error, CustomStringConvertible {
    var seen: String
    var description: String { "timed out; events so far: \(seen)" }
}

/// Collects a stream's elements on a task of its own, so each wait for the next one is bounded
/// and a missing event fails the test instead of hanging it.
final class Collected<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var elements: [Element] = []
    private var read = 0
    private var reader: Task<Void, Never>?

    init(_ stream: AsyncStream<Element>) {
        reader = Task { [weak self] in
            for await element in stream {
                guard let self else { return }
                self.lock.withLock { self.elements.append(element) }
            }
        }
    }

    deinit { reader?.cancel() }

    /// The next element not yet returned, waiting at most `seconds` for it.
    func next(within seconds: Double = 20) async throws -> Element {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let element = lock.withLock { () -> Element? in
                guard read < elements.count else { return nil }
                read += 1
                return elements[read - 1]
            }
            if let element { return element }
            guard Date() < deadline else {
                throw TimedOut(seen: "\(lock.withLock { elements })")
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Every element returned so far.
    var returned: [Element] { lock.withLock { Array(elements.prefix(read)) } }
}

/// An engine playing through a `DeviceOutput` on a null device, and every update it published.
final class Rig: @unchecked Sendable {
    let device: NullDevice
    let output: DeviceOutput
    let engine: PlaybackEngine
    private let updates: Collected<PlaybackUpdate>

    /// `formats` narrows what the device reports, and so what it plays tracks as.
    init(speed: Double = 4, digitalVolume: Bool = false, formats: DeviceFormats? = nil)
        async throws
    {
        device = NullDevice(speed: speed, keepsSamples: true)
        if let formats { device.report(formats) }
        output = try DeviceOutput(
            DeviceChoice(provider: device, digitalVolume: digitalVolume, gain: 1, formats: nil))
        engine = PlaybackEngine(output: output)
        updates = Collected(await engine.updates())
    }

    deinit { output.close() }

    var seen: [PlaybackUpdate] { updates.returned }

    /// Waits up to `seconds` for the first update from now that matches, and returns it.
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

    func wait(for event: PlaybackEvent) async throws {
        try await wait { $0.event == event }
    }

    var events: [PlaybackEvent] { seen.compactMap(\.event) }
}

func album(_ rate: Int, _ bits: Int) throws -> RampAlbum {
    try rampAlbum(
        sampleRateHz: rate, bitsPerSample: bits, in: try defaultPlaybackFixturesDirectory())
}

/// Where `album`'s frames start in `samples`, and how many of them follow in order from there.
func contiguousFrames(of album: RampAlbum, from first: Int = 0, in samples: [Int32])
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
    #expect(try #require(changes[1].switchSeconds) < 0.5)
    // The next track was decoded ahead, so the switch only copies it in.
    #expect(changes[1].steps?.map(\.name) == ["stop", "write", "start", "other"])
    let steps = try #require(changes[1].steps).reduce(0) { $0 + $1.seconds }
    #expect(abs(steps - (changes[1].switchSeconds ?? 0)) < 0.001)
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

/// Which call of `step` is the rate switch's when two tracks of different rates play: the first
/// track configures and starts once, and nothing stops before the switch.
private func switchCall(_ step: NullDevice.SessionStep) -> Int { step == .stop ? 1 : 2 }

/// Gone before the step's error, and a moment after it, within the settle time.
private let goneBeforeAndAfterTheError = [0, DeviceOutput.deviceSettleSeconds / 5]

@Test(arguments: NullDevice.SessionStep.allCases, goneBeforeAndAfterTheError)
func theDeviceGoingAwayAtEachStepOfARateSwitchIsReportedLost(
    _ step: NullDevice.SessionStep, _ goneAfterSeconds: Double
) async throws {
    let low = try album(44_100, 16)
    let high = try album(96_000, 24)
    let rig = try await Rig(speed: 1)
    rig.device.goAway(
        during: step, call: switchCall(step), afterSeconds: goneAfterSeconds)
    await rig.engine.setQueue([low.tracks[0], high.tracks[1]])
    await rig.engine.play()
    let lost = try await rig.wait { $0.event == .deviceLost }
    #expect(lost.state.status == .paused)
    #expect(lost.state.currentIndex == 1)
    #expect(rig.device.openSessionCount == 0)
    #expect(!rig.events.contains { if case .trackFailed = $0 { true } else { false } })
    #expect(!rig.events.contains { if case .failed = $0 { true } else { false } })
    #expect(await rig.engine.position() == 0)

    rig.device.plugIn()
    try await rig.wait(for: .deviceReturned)
    await rig.engine.play()
    try await rig.wait(for: .finished)
    let resumed = try #require(rig.device.captured.last)
    #expect(resumed.sampleRateHz == 96_000)
    let frame = high.trackFrames[0]
    #expect(contiguousFrames(of: high, from: frame, in: resumed.samples)?.start == 0)
}

@Test func aDeviceThatRefusesARateSwitchStopsPlaybackInsteadOfFailingTheTrack() async throws {
    let low = try album(44_100, 16)
    let high = try album(96_000, 24)
    let rig = try await Rig()
    rig.device.refuse(.configure, call: switchCall(.configure))
    await rig.engine.setQueue([low.tracks[0], high.tracks[1], low.tracks[1]])
    await rig.engine.play()

    let failed = try await rig.wait { if case .failed = $0.event { true } else { false } }
    #expect(failed.state.status == .stopped)
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(!rig.events.contains { if case .trackFailed = $0 { true } else { false } })
    #expect(!rig.events.contains(.trackStarted(index: 2)))
    #expect(rig.device.openSessionCount == 0)
}

@Test func aDeviceThatReadsAsGoneOnlyAfterTheSettleIsStillOfferedForResume() async throws {
    let low = try album(44_100, 16)
    let high = try album(96_000, 24)
    let rig = try await Rig(speed: 1)
    rig.device.goAway(
        during: .start, call: switchCall(.start),
        afterSeconds: DeviceOutput.deviceSettleSeconds * 3)
    await rig.engine.setQueue([low.tracks[0], high.tracks[1]])
    await rig.engine.play()

    // The device still reads as there when the step fails, so the output failed; once it
    // reads as gone, that's a loss, and its return is offered.
    let failed = try await rig.wait { if case .failed = $0.event { true } else { false } }
    #expect(failed.state.status == .stopped)
    let lost = try await rig.wait { $0.event == .deviceLost }
    #expect(lost.state.device == .lost)
    rig.device.plugIn()
    let returned = try await rig.wait { $0.event == .deviceReturned }
    #expect(returned.state.device == .returned)
}

@Test func aFileCutShortWhilePlayingIsReportedAndSkipped() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cut-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cut = directory.appendingPathComponent("cut.flac")
    try FileManager.default.copyItem(
        at: try hiResTrack(in: try defaultPlaybackFixturesDirectory()), to: cut)
    let next = try album(44_100, 16).tracks[1]

    let rig = try await Rig(speed: 1)
    await rig.engine.setQueue([cut, next])
    await rig.engine.play()
    try await rig.wait(for: .trackStarted(index: 0))
    // What's left of the file goes, as when the NAS drops while it plays.
    #expect(truncate(cut.path, 256 * 1024) == 0)
    try await rig.wait(for: .trackStarted(index: 1))
    #expect(
        rig.events.contains { event in
            guard case .trackFailed(cut, let reason) = event else { return false }
            return reason.contains(endedEarlyText)
        })
    let ended = try #require(await rig.engine.position())
    #expect(ended < 1, "the next track plays from its start")
}

/// What `DeviceOutputError.endedEarly` says, whatever the times.
private let endedEarlyText = "the file is cut short"

/// MPEG-1 Layer III frames of silence at 128 kbit/s and 44.1 kHz, `stored` of them in the file,
/// the first an Info frame stating `stated` when given, as an encoder that wrote a length would.
private func silentMP3(stored: Int, stated: Int?) -> Data {
    let frameBytes = 144 * 128_000 / 44_100
    func frame() -> [UInt8] {
        [0xFF, 0xFB, 0x90, 0x00] + [UInt8](repeating: 0, count: frameBytes - 4)
    }
    var first = frame()
    if let stated {
        // After the header and 32 bytes of stereo side information: "Info", flags, frames.
        let info =
            Array("Info".utf8) + [0, 0, 0, 1]
            + withUnsafeBytes(of: UInt32(stated).bigEndian, Array.init)
        first.replaceSubrange(36..<36 + info.count, with: info)
    }
    return Data(first + (1..<stored).flatMap { _ in frame() })
}

@Test func anMP3ThatStatesALongerLengthThanItHoldsIsReported() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mp3-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    // About 1.3 s of a stated 5.2 s, as a partial download leaves it.
    let partial = directory.appendingPathComponent("partial.mp3")
    try silentMP3(stored: 50, stated: 200).write(to: partial)
    // The same, stating nothing: its length is estimated from its size, so it isn't checked.
    let unstated = directory.appendingPathComponent("unstated.mp3")
    try silentMP3(stored: 50, stated: nil).write(to: unstated)

    let rig = try await Rig(speed: 8)
    await rig.engine.setQueue([partial, unstated])
    await rig.engine.play()
    try await rig.wait(for: .finished)
    let failures = rig.events.compactMap { event -> (URL, String)? in
        if case .trackFailed(let url, let reason) = event { (url, reason) } else { nil }
    }
    #expect(failures.map(\.0) == [partial])
    #expect(failures.first?.1.contains(endedEarlyText) == true)
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

/// The album's frames in `ranges`, one after another, as interleaved device samples.
private func samples(of album: RampAlbum, _ ranges: [Range<Int>]) -> [Int32] {
    ranges.flatMap { range in
        range.flatMap { index -> [Int32] in
            let (left, right) = album.frame(index)
            return [left, right]
        }
    }
}

@Test func changingTheNextTrackAfterItWasQueuedPlaysEverySampleOnce() async throws {
    let album = try album(44_100, 16)
    let first = 0..<album.trackFrames[0]
    let second = album.trackFrames[0]..<album.totalFrames
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
    let expected = samples(of: album, [first, first, second])
    let captured = rig.device.captured[0].samples
    #expect(captured.count >= expected.count)
    #expect(Array(captured.prefix(expected.count)) == expected)
}

@Test func aDeviceThatOpensIsNoLongerReportedAsReturning() async throws {
    let album = try album(44_100, 16)
    let device = NullDevice(speed: 8)
    let output = try DeviceOutput(
        DeviceChoice(provider: device, digitalVolume: false, gain: 1, formats: nil))
    defer { output.close() }
    let events = Collected(output.events)
    func next() async throws -> OutputEvent { try await events.next() }

    device.unplug()
    output.load(OutputItem(id: 1, url: album.tracks[1]), startSeconds: 0, playing: true)
    guard case .deviceLost = try await next() else {
        Issue.record("expected deviceLost")
        return
    }
    // The change notification is missed, but the next load opens the device anyway.
    device.plugInUnannounced()
    output.load(OutputItem(id: 2, url: album.tracks[1]), startSeconds: 0, playing: true)
    while true {
        if case .finished = try await next() { break }
    }
    // Now stopped, an unplug and replug must not report a return: nothing was waiting on it.
    device.unplug()
    device.plugIn()
    output.load(OutputItem(id: 3, url: album.tracks[1]), startSeconds: 0, playing: true)
    while true {
        let event = try await next()
        if case .deviceReturned = event { Issue.record("reported a return after a clean open") }
        if case .trackStarted = event { break }
    }
}

@Test func theControlThreadSleepsWhileStoppedWithNothingToDecode() {
    #expect(controlTickSeconds(running: true, fillDue: false) == 0.01)
    #expect(controlTickSeconds(running: false, fillDue: true) == 0.05)
    #expect(controlTickSeconds(running: false, fillDue: false) == nil)
}

@Test func theNullDevicesHALStepsTakeTheirTimeAndCloseRestoresTheFirstRate() throws {
    let delays = NullDevice.HALDelays(
        openSeconds: 0.02, rateChangeSeconds: 0.1, hogReleaseSeconds: 0.03)
    let device = NullDevice(delays: delays)
    device.changeRate(to: 48_000)
    let file = SignalFormat(
        formatID: linearPCMFormatID, sampleRateHz: 44_100, bitsPerChannel: 16, channels: 2,
        isFloat: false)
    func seconds(_ body: () throws -> Void) rethrows -> Double {
        let start = Date()
        try body()
        return Date().timeIntervalSince(start)
    }

    var session: (any PCMDevice)?
    #expect(try seconds { session = try device.open() } >= delays.openSeconds)
    let configure = { (rate: Double) in
        _ = try session!.configure(sampleRateHz: rate, channels: 2, forDoP: false, file: file)
    }
    #expect(try seconds { try configure(44_100) } >= delays.rateChangeSeconds)
    #expect(try seconds { try configure(44_100) } < delays.rateChangeSeconds)
    // Closing puts back 48 kHz and releases hog mode.
    #expect(
        try seconds { try session!.close() } >= delays.rateChangeSeconds + delays.hogReleaseSeconds)
    session = try device.open()
    #expect(try seconds { try configure(48_000) } < delays.rateChangeSeconds)
    try session!.close()
}

@Test func theNullDeviceTimesTheFirstCycleThatCarriesSound() async throws {
    let directory = try defaultPlaybackFixturesDirectory()
    let burst = try burstTrack(in: directory).url
    let device = NullDevice(speed: 8)
    let output = try DeviceOutput(
        DeviceChoice(provider: device, digitalVolume: false, gain: 1, formats: nil))
    defer { output.close() }

    device.listenForSound()
    let start = DispatchTime.now().uptimeNanoseconds
    output.load(OutputItem(id: 1, url: burst), startSeconds: 0, playing: true)
    // The burst starts 10 s in, 1.25 s at 8 times real time.
    #expect(device.soundStarted(within: 0.5) == nil)
    let sound = try #require(device.soundStarted(within: 5))
    let seconds = Double(sound - start) / 1e9
    #expect(seconds > BurstTrack.burstSeconds.lowerBound / 8 - 0.1)
    #expect(seconds < BurstTrack.burstSeconds.lowerBound / 8 + 0.5)
}

/// Plays `first` on `rig`, pauses it, then double-clicks `second` and plays it to its end.
/// Returns the frames the device pulled before the pause.
private func doubleClick(_ second: URL, after first: URL, on rig: Rig) async throws -> Int {
    await rig.engine.setQueue([first])
    await rig.engine.play()
    try await rig.wait(for: .trackStarted(index: 0))
    try await Task.sleep(nanoseconds: 100_000_000)
    await rig.engine.pause()
    try await Task.sleep(nanoseconds: 50_000_000)
    let pulled = rig.device.captured[0].samples.count / 2
    let filling = await rig.engine.play(starting: second) { ([second], 0) }
    try await filling.value
    try await rig.wait(for: .finished)
    return pulled
}

@Test func aDoubleClickWhilePlayingKeepsTheDeviceOpenAndStreamsOn() async throws {
    let album = try album(44_100, 16)
    let rig = try await Rig(speed: 1)
    let pulled = try await doubleClick(album.tracks[1], after: album.tracks[0], on: rig)

    #expect(rig.device.openedSessionCount == 1)
    let runs = rig.device.captured
    #expect(runs.map(\.sampleRateHz) == [44_100])
    // The second track from its first frame, straight after what played of the first.
    let second = try #require(
        contiguousFrames(of: album, from: album.trackFrames[0], in: runs[0].samples))
    #expect(second.start == pulled)
    #expect(second.count == album.trackFrames[1])
    #expect(rig.device.openSessionCount == 0)
}

@Test func aDoubleClickOnAnotherRateReconfiguresTheOpenDevice() async throws {
    let low = try album(44_100, 16)
    let high = try album(96_000, 24)
    let rig = try await Rig(speed: 1)
    _ = try await doubleClick(high.tracks[0], after: low.tracks[0], on: rig)

    #expect(rig.device.openedSessionCount == 1)
    let runs = rig.device.captured
    #expect(runs.map(\.sampleRateHz) == [44_100, 96_000])
    let second = try #require(contiguousFrames(of: high, in: runs[1].samples))
    #expect(second.start == 0)
    #expect(second.count == high.trackFrames[0])
}

@Test func stopAndANewQueueWithoutPlayStillCloseTheDevice() async throws {
    let album = try album(44_100, 16)
    let rig = try await Rig(speed: 1)
    await rig.engine.setQueue([album.tracks[0]])
    await rig.engine.play()
    try await rig.wait(for: .trackStarted(index: 0))
    await rig.engine.stop()
    try await waitUntil { rig.device.openSessionCount == 0 }

    _ = await rig.engine.play(starting: album.tracks[0]) { ([album.tracks[0]], 0) }
    try await rig.wait(for: .trackStarted(index: 0))
    await rig.engine.setQueue([album.tracks[1]])
    try await waitUntil { rig.device.openSessionCount == 0 }
    #expect(rig.device.openedSessionCount == 2)
}

/// The play-to-first-sample interval a play opens is ended by the control thread once the
/// device has taken a sample, never by the IO proc. Other tests play at once, so this looks for
/// any such interval that ended after its own play.
@Test func aPlaysFirstSampleEndsItsInterval() async throws {
    let album = try album(44_100, 16)
    let rig = try await Rig(speed: 1)
    let start = DispatchTime.now().uptimeNanoseconds
    _ = await rig.engine.play(starting: album.tracks[0]) { ([album.tracks[0]], 0) }
    try await rig.wait(for: .trackStarted(index: 0))
    try await waitUntil {
        IntervalLog.shared.spans(from: start, to: .max).contains {
            $0.interval == .playToFirstSample && $0.start >= start && $0.end != nil
        }
    }
}

/// An interval begun while audio from an earlier load plays isn't ended by that audio: only the
/// start of what the load queues, once the control thread has processed it, can end it.
@Test func audioFromBeforeALoadDoesNotEndItsFirstSoundInterval() async throws {
    let album = try album(44_100, 16)
    let device = NullDevice(speed: 1)
    let interval = PendingInterval(.playToFirstSample)
    let output = try DeviceOutput(
        DeviceChoice(provider: device, digitalVolume: false, gain: 1, formats: nil),
        firstSound: interval)
    defer { output.close() }
    output.load(OutputItem(id: 1, url: album.tracks[0]), startSeconds: 0, playing: true)
    try await waitUntil { !interval.isOpen }

    // A begin whose load the control thread hasn't processed yet, while track 1 plays on.
    interval.begin()
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(interval.isOpen)

    output.load(OutputItem(id: 2, url: album.tracks[1]), startSeconds: 0, playing: true)
    try await waitUntil { !interval.isOpen }
}

/// A stop posted before a second play's begin doesn't cancel that play's interval. The first
/// load's audio ending it is covered in `StallDetectorTests`: the null device takes its first
/// buffer as soon as it starts, so a test can't hold that audio back.
@Test func aNewerPlaysIntervalIsNotEndedOrCancelledByAnEarlierCommand() async throws {
    let album = try album(44_100, 16)
    // Slow enough that the first load's audio hasn't been taken when the second play begins.
    let device = NullDevice(speed: 0.05)
    let interval = PendingInterval(.playToFirstSample)
    let output = try DeviceOutput(
        DeviceChoice(provider: device, digitalVolume: false, gain: 1, formats: nil),
        firstSound: interval)
    defer { output.close() }
    output.load(OutputItem(id: 1, url: album.tracks[0]), startSeconds: 0, playing: true)
    try await Task.sleep(nanoseconds: 30_000_000)
    interval.begin()
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(interval.isOpen)

    // A stop posted before the begin that follows must not cancel it.
    output.stop()
    output.load(OutputItem(id: 2, url: album.tracks[1]), startSeconds: 0, playing: true)
    try await Task.sleep(nanoseconds: 30_000_000)
    #expect(interval.isOpen)
    try await waitUntil { !interval.isOpen }
}

/// A load or seek that makes no sound cancels the interval, so a later play doesn't log the
/// idle time.
@Test func aPlayThatMakesNoSoundCancelsItsFirstSoundInterval() async throws {
    let album = try album(44_100, 16)
    let device = NullDevice(speed: 1)
    let interval = PendingInterval(.playToFirstSample)
    let output = try DeviceOutput(
        DeviceChoice(provider: device, digitalVolume: false, gain: 1, formats: nil),
        firstSound: interval)
    defer { output.close() }
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-\(UUID()).flac")

    output.load(OutputItem(id: 1, url: missing), startSeconds: 0, playing: true)
    try await waitUntil { !interval.isOpen }

    output.load(OutputItem(id: 2, url: album.tracks[0]), startSeconds: 0, playing: true)
    try await waitUntil { !interval.isOpen }
    output.load(OutputItem(id: 3, url: album.tracks[1]), startSeconds: 0, playing: true)
    output.pause()
    try await waitUntil { !interval.isOpen }

    device.unplug()
    output.load(OutputItem(id: 4, url: album.tracks[0]), startSeconds: 0, playing: true)
    try await waitUntil { !interval.isOpen }
}

/// Polls `condition` every 5 ms for up to 5 s.
private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
        guard Date() < deadline else { throw TimedOut(seen: "the condition never held") }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

/// `album`'s tracks copied into a temporary folder, so a test can delete them under the output.
private func copies(of album: RampAlbum) throws -> [URL] {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("open-tracks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return try album.tracks.map { track in
        let copy = folder.appendingPathComponent(track.lastPathComponent)
        try FileManager.default.copyItem(at: track, to: copy)
        return copy
    }
}

@Test func nextPlaysTheTrackTheOutputAlreadyOpened() async throws {
    let album = try album(44_100, 16)
    let tracks = try copies(of: album)
    defer { try? FileManager.default.removeItem(at: tracks[0].deletingLastPathComponent()) }
    let rig = try await Rig(speed: 1)
    await rig.engine.setQueue(tracks)
    await rig.engine.play()
    try await rig.wait(for: .trackStarted(index: 0))
    await rig.engine.pause()
    try await Task.sleep(nanoseconds: 50_000_000)
    let pulled = rig.device.captured[0].samples.count / 2
    // Opening the file again would fail now.
    try FileManager.default.removeItem(at: tracks[1])
    await rig.engine.next()
    await rig.engine.play()
    try await rig.wait(for: .finished)

    #expect(!rig.events.contains { if case .trackFailed = $0 { true } else { false } })
    let second = try #require(
        contiguousFrames(of: album, from: album.trackFrames[0], in: rig.device.captured[0].samples))
    #expect(second.start == pulled)
    #expect(second.count == album.trackFrames[1])
}

@Test func aSeekAfterDecodingMovedOnUsesTheOpenFile() async throws {
    let album = try album(44_100, 16)
    let tracks = try copies(of: album)
    defer { try? FileManager.default.removeItem(at: tracks[0].deletingLastPathComponent()) }
    let rig = try await Rig(speed: 1)
    await rig.engine.setQueue(tracks)
    await rig.engine.play()
    try await rig.wait(for: .trackStarted(index: 0))
    // The first track is shorter than the ring buffer, so decoding moved on at once.
    try await Task.sleep(nanoseconds: 100_000_000)
    await rig.engine.pause()
    try await Task.sleep(nanoseconds: 50_000_000)
    let pulled = rig.device.captured[0].samples.count / 2
    try FileManager.default.removeItem(at: tracks[0])
    await rig.engine.seek(toSeconds: 0.5)
    await rig.engine.play()
    try await rig.wait(for: .finished)

    #expect(!rig.events.contains { if case .trackFailed = $0 { true } else { false } })
    // From half a second in, through the second track without a gap.
    let after = try #require(
        contiguousFrames(of: album, from: 22_050, in: rig.device.captured[0].samples))
    #expect(after.start == pulled)
    #expect(after.count == album.totalFrames - 22_050)
}

/// On a NAS the control thread can take a while to do a seek, and until it has, the position
/// it last published is from before the seek.
@Test func aSeekReportsItsTargetFromTheMomentItIsAskedFor() async throws {
    let track = try hiResTrack(in: try defaultPlaybackFixturesDirectory())
    let device = NullDevice(speed: 1)
    let output = try DeviceOutput(
        DeviceChoice(provider: device, digitalVolume: false, gain: 1, formats: nil),
        fileLatency: FileLatency(openSeconds: 0, readSeconds: 0.05))
    defer { output.close() }
    let engine = PlaybackEngine(output: output)
    let updates = Collected(await engine.updates())
    await engine.setQueue([track])
    await engine.play()
    while try await updates.next().event != .trackStarted(index: 0) {}
    let started = Date().addingTimeInterval(10)
    while await engine.position() ?? 0 < 0.2, Date() < started {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let before = try #require(await engine.position())
    #expect(before >= 0.2 && before < 5)
    await engine.seek(toSeconds: 60)
    var seen: [Double] = []
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline, seen.last ?? 0 < 60.1 {
        seen.append(try #require(await engine.position()))
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    #expect(seen.first == 60)
    #expect(seen.allSatisfy { $0 >= 60 && $0 < 61 }, "positions after the seek: \(seen)")
    #expect((seen.last ?? 0) >= 60.1, "playback never moved on from the seek: \(seen)")
}
