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
