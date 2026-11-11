import CoreAudio
import Foundation
import HALRender
import Testing

@testable import Fixtures
@testable import HALOutput
@testable import Log
@testable import Playback

/// A device that plays only when the test pulls from it: its IO proc runs on the test's thread,
/// for as many frames as the test asks. It takes every track as stereo 32-bit integers at its
/// own rate, as the null device does.
final class StillDevice: PCMDeviceProvider, @unchecked Sendable {
    // One test's thread uses it, between the passes it runs, so nothing here needs a lock.
    let deviceName = "still device"
    var deviceUID: String { deviceName }
    let usesHogMode = true
    private var connected = true
    private var changed: (@Sendable () -> Void)?
    /// The render the IO proc reads while the device runs.
    fileprivate var render: OpaquePointer?

    func open() throws -> (any PCMDevice)? { connected ? StillSession(self) : nil }
    func isConnected() -> Bool { connected }
    func watch(
        _ changed: @escaping @Sendable () -> Void,
        state: @escaping @Sendable (DeviceState) -> Void
    ) throws { self.changed = changed }
    func stopWatching() { changed = nil }
    func deviceReturned() {}

    func unplug() {
        connected = false
        changed?()
    }

    /// Runs the IO proc for `frames` frames, in cycles of 512 as a device would, and returns the
    /// interleaved samples it wrote.
    func pull(frames: Int) -> [Int32] {
        guard let render else { preconditionFailure("the still device isn't running") }
        var samples = [Int32](repeating: 0, count: frames * 2)
        samples.withUnsafeMutableBytes { bytes in
            var done = 0
            while done < frames {
                let cycle = min(512, frames - done)
                var time = AudioTimeStamp()
                var input = AudioBufferList()
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 2, mDataByteSize: UInt32(cycle * 8),
                        mData: bytes.baseAddress! + done * 8))
                _ = HALRenderIOProc(
                    0, &time, &input, &time, &list, &time, UnsafeMutableRawPointer(render))
                done += cycle
            }
        }
        return samples
    }
}

private final class StillSession: PCMDevice {
    private let device: StillDevice

    init(_ device: StillDevice) { self.device = device }

    func configure(sampleRateHz: Double, channels: UInt32, forDoP: Bool, file: SignalFormat)
        throws -> DeviceFormat
    {
        DeviceFormat(
            stream: NullDevice.format(sampleRateHz: sampleRateHz), summary: device.deviceName,
            shown: device.deviceName, latencySeconds: 0.01, isConverted: false)
    }
    func start(_ render: OpaquePointer) throws { device.render = render }
    func stop() throws { device.render = nil }
    func close() throws { device.render = nil }
    func abandon() -> Bool {
        device.render = nil
        return true
    }
}

/// A `DeviceOutput` on a still device whose control thread the test runs, one pass at a time,
/// with the count of bytes consumed, the clock and what happens after each chunk of a refill in
/// the test's hands.
final class Stepped {
    let device = StillDevice()
    let interval = PendingInterval(.playToFirstSample)
    var consumed: UInt64 = 0
    var now = 0.0
    var onChunk: (() -> Void)?
    private(set) var output: DeviceOutput!
    private(set) var events: Collected<OutputEvent>!

    /// `countedByTheIOProc` leaves the count of bytes consumed to the IO proc the test pulls.
    init(countedByTheIOProc: Bool = false) throws {
        let counted: (() -> UInt64)? = { [weak self] in self?.consumed ?? 0 }
        let control = ControlSeam(
            startThread: false, consumed: countedByTheIOProc ? nil : counted,
            now: { [weak self] in self?.now ?? 0 }, afterChunk: { [weak self] in self?.onChunk?() })
        output = try DeviceOutput(
            DeviceChoice(provider: device, digitalVolume: false, gain: 1, formats: nil),
            firstSound: interval, diagnostics: OutputDiagnostics(), control: control)
        events = Collected(output.events)
    }

    deinit { output.close() }

    func step() { output.step() }

    /// The next format change reported for `item`.
    func formatChange(for item: OutputItem.ID) async throws -> FormatChange {
        while true {
            if case .formatChanged(item, let change) = try await events.next() { return change }
        }
    }
}

/// Bytes of a stereo 32-bit frame on the still device.
private let frameBytes = 8
private let chunkFrames = 32768

private func burst() throws -> URL {
    try burstTrack(in: try defaultPlaybackFixturesDirectory()).url
}

private func bytes(seconds: Double) -> UInt64 { UInt64(seconds * 44_100) * UInt64(frameBytes) }

// MARK: The position during a refill (6144577a, f4f43bbf)

/// A refill on a NAS takes hundreds of milliseconds, while the IO proc plays on: the position is
/// published after each chunk written, not only once the refill is done.
@Test func positionIsPublishedAfterEachChunkOfARefill() throws {
    let stepped = try Stepped()
    var seen: [OutputPosition?] = []
    stepped.onChunk = {
        seen.append(stepped.output.position())
        stepped.consumed += UInt64(chunkFrames * frameBytes)
    }
    stepped.output.load(OutputItem(id: 1, url: try burst()), startSeconds: 0, playing: true)
    stepped.step()

    // Each chunk sees what the one before it published: the count after that chunk.
    #expect(seen.count > 3)
    #expect(seen.first == .some(nil))
    let expected = (1..<seen.count).map {
        OutputPosition(item: 1, seconds: Double($0 * chunkFrames) / 44_100)
    }
    #expect(Array(seen.dropFirst()) == expected)
}

/// A gapless boundary the IO proc passes while the refill writes the next track is announced
/// before the refill publishes the position, which would otherwise read past the old track's end.
@Test func aBoundaryCrossedInsideARefillIsAnnouncedBeforeThePositionIsPublished() throws {
    let album = try album(44_100, 16)
    let stepped = try Stepped()
    // The IO proc has played the first track to its end and a frame of the next.
    stepped.consumed = UInt64((album.trackFrames[0] + 1) * frameBytes)
    var seen: [OutputPosition] = []
    stepped.onChunk = { stepped.output.position().map { seen.append($0) } }
    stepped.output.load(
        OutputItem(id: 1, url: album.tracks[0]), next: OutputItem(id: 2, url: try burst()),
        startSeconds: 0, playing: true)
    stepped.step()

    let first = Double(album.trackFrames[0]) / 44_100
    let second = try #require(seen.firstIndex { $0.item == 2 }, "\(seen)")
    #expect(seen[second] == OutputPosition(item: 2, seconds: 1 / 44_100))
    #expect(seen[second...].allSatisfy { $0.item == 2 })
    #expect(seen[..<second].allSatisfy { $0.item == 1 && $0.seconds > first })
}

// MARK: A seek's target (246364e1)

/// Until the pass that does a seek is over, the position is the seek's target: what the output
/// published is from before it. A second seek posted while the first is done keeps its own
/// target until its own pass.
@Test func aSeekIsReportedAtItsTargetUntilThePassThatDoesItIsOver() throws {
    // Shorter than the ring buffer, which the still device never drains, so a seek's prefill
    // has room to write.
    let album = try album(44_100, 16)
    let stepped = try Stepped()
    stepped.output.load(OutputItem(id: 1, url: album.tracks[0]), startSeconds: 0, playing: true)
    stepped.step()
    stepped.consumed = bytes(seconds: 0.25)
    stepped.step()
    #expect(stepped.output.position() == OutputPosition(item: 1, seconds: 0.25))

    // Off a frame, so the target differs from the position published once it's done.
    let first = 0.5 + 0.4 / 44_100
    let second = 0.7 + 0.4 / 44_100
    stepped.output.seek(toSeconds: first)
    #expect(stepped.output.position()?.seconds == first)
    var during: [Double?] = []
    stepped.onChunk = {
        during.append(stepped.output.position()?.seconds)
        if during.count == 1 { stepped.output.seek(toSeconds: second) }
    }
    stepped.step()
    #expect(during == [first])
    #expect(stepped.output.position()?.seconds == second)

    stepped.onChunk = nil
    stepped.step()
    let sought = Double(Int(second * 44_100)) / 44_100
    #expect(stepped.output.position() == OutputPosition(item: 1, seconds: sought))
}

// MARK: The first-sound interval (6d416c06, 7b935bd0)

/// A command posted before a newer play began neither ends that play's interval with its own
/// audio nor cancels it.
@Test func aCommandFromBeforeANewerPlayNeitherEndsNorCancelsItsInterval() throws {
    let stepped = try Stepped()
    let interval = stepped.interval
    stepped.output.load(OutputItem(id: 1, url: try burst()), startSeconds: 0, playing: true)
    // A newer play begun on another thread before the control thread got to the load.
    interval.begin()
    stepped.step()
    stepped.consumed = bytes(seconds: 1)
    stepped.step()
    #expect(interval.isOpen, "the earlier load's audio ended the newer play's interval")

    stepped.output.stop()
    interval.begin()
    stepped.step()
    #expect(interval.isOpen, "a stop posted before the play cancelled its interval")

    stepped.output.load(OutputItem(id: 2, url: try burst()), startSeconds: 0, playing: true)
    stepped.consumed = .max / 2
    stepped.step()
    #expect(!interval.isOpen)
}

/// An interval begun while an earlier load's audio plays on is ended only by the start of the
/// audio its own load queues, once the control thread has done that load.
@Test func audioFromBeforeALoadDoesNotEndItsFirstSoundInterval() throws {
    let stepped = try Stepped()
    let interval = stepped.interval
    stepped.output.load(OutputItem(id: 1, url: try burst()), startSeconds: 0, playing: true)
    stepped.step()
    #expect(interval.isOpen)
    stepped.consumed = bytes(seconds: 1)
    stepped.step()
    #expect(!interval.isOpen)

    // A begin whose load the control thread hasn't done yet, while track 1 plays on.
    interval.begin()
    stepped.consumed = bytes(seconds: 2)
    stepped.step()
    #expect(interval.isOpen)

    // The load queues its audio after what's written, which the IO proc hasn't reached.
    stepped.output.load(OutputItem(id: 2, url: try burst()), startSeconds: 0, playing: true)
    stepped.step()
    #expect(interval.isOpen)
    stepped.consumed = .max / 2
    stepped.step()
    #expect(!interval.isOpen)
}

/// A load or seek that makes no sound cancels the interval, so a later play doesn't log the idle
/// time: a file that won't open, a pause, and a device that's gone.
@Test func aPlayThatMakesNoSoundCancelsItsFirstSoundInterval() throws {
    let album = try album(44_100, 16)
    let stepped = try Stepped()
    let interval = stepped.interval
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-\(UUID()).flac")
    stepped.output.load(OutputItem(id: 1, url: missing), startSeconds: 0, playing: true)
    stepped.step()
    #expect(!interval.isOpen)

    // The IO proc never reaches the new audio, so only a cancel closes the interval.
    stepped.output.load(OutputItem(id: 2, url: album.tracks[0]), startSeconds: 0, playing: true)
    stepped.output.pause()
    stepped.step()
    #expect(!interval.isOpen)

    stepped.device.unplug()
    stepped.output.load(OutputItem(id: 3, url: album.tracks[1]), startSeconds: 0, playing: true)
    stepped.step()
    #expect(!interval.isOpen)
}

// MARK: Decoding ahead of a switch (8e308a5d)

/// The next track's start, decoded ahead while the current one drains, is stale once a seek
/// has it decoded ahead again: when that fails, the switch decodes the track afresh instead of
/// copying in audio from before the seek.
@Test func aDecodeAheadThatFailsAfterASeekLeavesNoStaleAudioForTheSwitch() async throws {
    let album = try album(44_100, 16)
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("stepped-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    // A second of DSD64, which needs a format switch from the PCM track before it.
    let dsd = folder.appendingPathComponent("next.dsf")
    let channel = Data((0..<352_800).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    try dsfFile(rateHz: 2_822_400, channels: [channel, channel]).write(to: dsd)

    let stepped = try Stepped()
    stepped.output.load(
        OutputItem(id: 1, url: album.tracks[0]), next: OutputItem(id: 2, url: dsd),
        startSeconds: 0, playing: true)
    stepped.step()
    // The open file now fails every read, so the next decode-ahead fails.
    #expect(truncate(dsd.path, 0) == 0)
    stepped.output.seek(toSeconds: 0.2)
    stepped.step()

    // The IO proc takes everything, and the device has had its latency to play it.
    stepped.consumed = .max / 2
    stepped.step()
    stepped.now += 1
    stepped.step()
    let change = try await stepped.formatChange(for: 2)
    let steps = try #require(change.steps).map(\.name)
    #expect(!steps.contains("write"), "the switch copied in stale audio: \(steps)")
    #expect(steps.contains("prefill"))
}

// MARK: Replacing a queued next track (2c77214f, 7ddef2df)

/// The interleaved samples of `album`'s frames in `ranges`, one after another.
private func samples(of album: RampAlbum, _ ranges: [Range<Int>]) -> [Int32] {
    ranges.flatMap { range in
        range.flatMap { index -> [Int32] in
            let (left, right) = album.frame(index)
            return [left, right]
        }
    }
}

/// A next track already queued behind the current one is replaced without a sample of the
/// current one lost or played twice, wherever the IO proc is in it.
@Test func replacingAQueuedNextTrackPlaysEverySampleOnce() throws {
    let album = try album(44_100, 16)
    let first = 0..<album.trackFrames[0]
    let stepped = try Stepped(countedByTheIOProc: true)
    stepped.output.load(
        OutputItem(id: 1, url: album.tracks[0]), next: OutputItem(id: 2, url: album.tracks[1]),
        startSeconds: 0, playing: true)
    stepped.step()
    var pulled = stepped.device.pull(frames: 10_000)
    // Repeat one: the first track again in place of the second.
    stepped.output.setNext(OutputItem(id: 3, url: album.tracks[0]))
    stepped.step()
    pulled += stepped.device.pull(frames: 2 * album.trackFrames[0] - 10_000)
    #expect(pulled == samples(of: album, [first, first]))
}

/// A boundary the IO proc has already passed belongs to the track playing now, which a new next
/// track follows rather than cuts off.
@Test func replacingTheNextTrackAfterItStartedKeepsIt() throws {
    let album = try album(44_100, 16)
    let first = 0..<album.trackFrames[0]
    let second = album.trackFrames[0]..<album.totalFrames
    let stepped = try Stepped(countedByTheIOProc: true)
    stepped.output.load(
        OutputItem(id: 1, url: album.tracks[0]), next: OutputItem(id: 2, url: album.tracks[1]),
        startSeconds: 0, playing: true)
    stepped.step()
    let into = album.trackFrames[0] + 1_000
    var pulled = stepped.device.pull(frames: into)
    stepped.output.setNext(OutputItem(id: 3, url: album.tracks[0]))
    stepped.step()
    pulled += stepped.device.pull(frames: album.totalFrames + album.trackFrames[0] - into)
    #expect(pulled == samples(of: album, [first, second, first]))
}
