import Foundation
import Testing

@testable import Fixtures
@testable import HALOutput
@testable import Playback

/// A DSD track's file, and each channel's bytes as they should arrive, oldest bit highest,
/// padded with idle to whole pairs of frames.
private struct DSDTrack {
    let url: URL
    let expected: [[UInt8]]
}

private let folder: URL = {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("dop-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}()

private func dsdTrack(
    _ name: String, rateHz: Int = 2_822_400, bytes: Int, seed: Int, dff: Bool = false
) throws -> DSDTrack {
    let channels = (0..<2).map { channel in
        (0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ channel &* 77 &+ seed) }
    }
    let url = folder.appendingPathComponent(name + (dff ? ".dff" : ".dsf"), isDirectory: false)
    let data = channels.map { Data($0) }
    try (dff ? dffFile(rateHz: rateHz, channels: data) : dsfFile(rateHz: rateHz, channels: data))
        .write(to: url)
    let padded = (bytes + 3) / 4 * 4
    return DSDTrack(
        url: url,
        expected: channels.map { $0 + Array(repeating: dsdIdleByte, count: padded - bytes) })
}

/// What a DoP stream in 32-bit samples carried: each channel's DSD bytes, oldest first, from
/// the first DoP frame to the last. Fails on a frame between them that isn't DoP, a marker
/// that doesn't alternate, channels with different markers, or a low byte that isn't zero.
/// `allowingGaps` lets through the zeros the IO proc pads with when a seek's discard finds the
/// new audio not yet written; the markers must still alternate across them.
private func unpack(_ samples: [Int32], allowingGaps: Bool = false) throws -> [[UInt8]] {
    func marker(_ sample: Int32) -> UInt8 {
        UInt8(truncatingIfNeeded: UInt32(bitPattern: sample) >> 24)
    }
    let frames = samples.count / 2
    let isDoP = { (frame: Int) in dopMarkers.contains(marker(samples[2 * frame])) }
    let first = try #require((0..<frames).first(where: isDoP), "no DoP frame")
    let last = (0..<frames).last(where: isDoP)!
    var channels: [[UInt8]] = [[], []]
    var previous: UInt8?
    for frame in first...last {
        let words = [samples[2 * frame], samples[2 * frame + 1]].map { UInt32(bitPattern: $0) }
        let mark = marker(samples[2 * frame])
        if allowingGaps, words == [0, 0] { continue }
        try #require(dopMarkers.contains(mark), "frame \(frame) of \(first)...\(last) isn't DoP")
        try #require(marker(samples[2 * frame + 1]) == mark, "frame \(frame)'s channels differ")
        try #require(mark != previous, "frame \(frame) repeats marker \(mark)")
        previous = mark
        for (channel, word) in words.enumerated() {
            try #require(word & 0xFF == 0, "frame \(frame) has a low byte")
            channels[channel] += [UInt8(word >> 16 & 0xFF), UInt8(word >> 8 & 0xFF)]
        }
    }
    return channels
}

@Test func aGaplessDSDAlbumKeepsItsMarkersAndBitsAcrossTheChange() async throws {
    // An odd byte count, so the first track ends on a half frame and an odd frame, both padded.
    let one = try dsdTrack("one", bytes: 70_001, seed: 1)
    let two = try dsdTrack("two", bytes: 40_000, seed: 2, dff: true)
    // At real-time pace, so the DoP tail lasts as long against the drain as it would on a DAC.
    let rig = try await Rig(speed: 1)
    await rig.engine.setQueue([one.url, two.url])
    await rig.engine.play()
    try await rig.wait(for: .finished)

    let runs = rig.device.captured
    #expect(runs.map(\.sampleRateHz) == [176_400])
    let carried = try unpack(runs[0].samples)
    for channel in 0..<2 {
        let audio = one.expected[channel] + two.expected[channel]
        #expect(Array(carried[channel].prefix(audio.count)) == audio)
        // Then DoP silence until the device stopped, never zeros: the last frame is DoP.
        let tail = carried[channel].dropFirst(audio.count)
        #expect(!tail.isEmpty && tail.allSatisfy { $0 == dsdIdleByte })
    }
    let last = UInt32(bitPattern: runs[0].samples[runs[0].samples.count - 2]) >> 24
    #expect(dopMarkers.contains(UInt8(last)))
    #expect(rig.events.contains(.trackStarted(index: 1)))
    #expect(!rig.events.contains { if case .underrun = $0 { true } else { false } })
    let output = try #require(rig.seen.last { $0.state.outputFormat != nil }?.state.outputFormat)
    #expect(output.hasPrefix("null device: 176.4 kHz · ") && output.hasSuffix(", DoP"))
}

@Test func aSeekWhilePlayingKeepsTheMarkersAlternating() async throws {
    // Two seconds: DSD64 is 352,800 bytes a second a channel.
    let track = try dsdTrack("long", bytes: 2 * 352_800, seed: 3)
    let rig = try await Rig(speed: 2)
    await rig.engine.setQueue([track.url])
    await rig.engine.play()
    try await rig.wait(for: .trackStarted(index: 0))
    await rig.engine.seek(toSeconds: 1.5)
    try await rig.wait(for: .finished)

    let carried = try unpack(rig.device.captured[0].samples, allowingGaps: true)
    // From 1.5 s, 264,600 frames in, to the end.
    let tail = track.expected[0].suffix(from: 2 * 264_600)
    // Both end in DoP silence, the track's padding and the stream's tail; compare before it.
    func audio(_ bytes: some BidirectionalCollection<UInt8>) -> [UInt8] {
        Array(bytes.reversed().drop { $0 == dsdIdleByte }.reversed())
    }
    let played = audio(carried[0])
    #expect(played.suffix(audio(tail).count) == audio(tail)[...])
    #expect(carried[0].count < track.expected[0].count)
}

@Test func theVolumeNeverReachesDoP() async throws {
    let track = try dsdTrack("loud", bytes: 60_000, seed: 4)
    let rig = try await Rig(digitalVolume: true)
    let paths = Collected(rig.output.signalPaths)
    try await rig.engine.setVolume(0.5)
    await rig.engine.setQueue([track.url])
    await rig.engine.play()
    try await rig.wait(for: .trackStarted(index: 0))
    try await rig.engine.setVolume(0.25)
    try await rig.wait(for: .finished)

    #expect(
        try unpack(rig.device.captured[0].samples).enumerated().allSatisfy { channel, bytes in
            Array(bytes.prefix(track.expected[channel].count)) == track.expected[channel]
        })
    // The path the panel shows while it played: unity, so bit-perfect.
    var dop: SignalPath?
    while dop == nil {
        let path = try await paths.next()
        if path.track?.decoded.formatID == dopFormatID, signalVerdict(path) == .bitPerfect {
            dop = path
        }
    }
    guard case .device(let sink) = dop?.sink else {
        throw TimedOut(seen: "\(String(describing: dop))")
    }
    #expect(sink.gain == 1)
    #expect(
        dop?.track?.file
            == SignalFormat(
                formatID: dsdFormatID, sampleRateHz: 2_822_400, bitsPerChannel: 1, channels: 2,
                isFloat: false))
}

@Test func aDSDAlbumOnADeviceWithoutTheCarrierStopsAtTheFailureLimit() async throws {
    let album = try (0..<5).map {
        try dsdTrack("dsd128-\($0)", rateHz: 5_644_800, bytes: 4096, seed: $0)
    }
    let rig = try await Rig()
    rig.device.report(
        DeviceFormats(
            sampleRatesHz: [44_100...192_000],
            formats: [
                PhysicalFormat(
                    formatID: linearPCMFormatID, sampleRateHz: 44_100...768_000, bitsPerChannel: 32,
                    channels: 2, isFloat: false, isMixable: false)
            ]))
    await rig.engine.setQueue(album.map(\.url))
    await rig.engine.play()
    try await rig.wait { if case .failed = $0.event { true } else { false } }

    let refused = rig.events.compactMap { event -> (URL, String)? in
        guard case .trackFailed(let url, let problem) = event else { return nil }
        return (url, problem.message)
    }
    #expect(refused.map(\.0) == album.prefix(PlaybackEngine.failureLimit).map(\.url))
    #expect(
        refused.allSatisfy {
            $0.1.contains("null device can't play DSD128: it has no 352.8 kHz rate for DoP")
        })
    // The stop says the one cause, not only the count.
    guard case .failed(let stopped) = rig.events.last else {
        Issue.record("didn't stop: \(rig.events)")
        return
    }
    #expect(
        stopped.message
            == "\(PlaybackEngine.failureLimit) tracks in a row couldn't play: null device can't"
            + " play DSD128: it has no 352.8 kHz rate for DoP")
    #expect(stopped.causes.map(\.tracks) == [refused.map(\.0)] && stopped.fix == nil)
    #expect(rig.device.captured.isEmpty)
}

/// With hog mode off, a DSD album stops on the one cause, which carries its fix.
@Test func aDSDAlbumWithHogModeOffStopsOnTheHogModeFix() async throws {
    let album = try (0..<4).map { try dsdTrack("hogless-\($0)", bytes: 4096, seed: $0) }
    let rig = try await Rig()
    rig.device.setHogModeSetting(false)
    await rig.engine.setQueue(album.map(\.url))
    await rig.engine.play()
    let update = try await rig.wait { if case .failed = $0.event { true } else { false } }
    guard case .failed(let stopped) = update.event else { return }
    #expect(stopped.fix == .turnOnHogMode(deviceUID: rig.device.deviceUID))
    #expect(
        stopped.causes.count == 1 && stopped.causes[0].tracks.count == PlaybackEngine.failureLimit)
    #expect(
        stopped.message.hasSuffix("DoP needs exclusive access, and hog mode is off for this device")
    )
}

@Test func dsdNeedsHogModeAndANonMixableFormatOrIsRefused() async throws {
    let track = try dsdTrack("exclusive", bytes: 4096, seed: 9)
    let noHog = try await Rig()
    noHog.device.setHogModeSetting(false)
    await noHog.engine.setQueue([track.url])
    await noHog.engine.play()
    try await noHog.wait { if case .trackFailed = $0.event { true } else { false } }
    #expect(
        noHog.events.contains { event in
            guard case .trackFailed(track.url, let problem) = event else { return false }
            return problem.message
                == "null device can't play DSD64: DoP needs exclusive access, and hog mode is off"
                + " for this device"
        })

    let mixable = try await Rig()
    mixable.device.report(
        DeviceFormats(
            sampleRatesHz: [44_100...768_000],
            formats: [
                PhysicalFormat(
                    formatID: linearPCMFormatID, sampleRateHz: 44_100...768_000, bitsPerChannel: 32,
                    channels: 2, isFloat: false, isMixable: true)
            ]))
    await mixable.engine.setQueue([track.url])
    await mixable.engine.play()
    try await mixable.wait { if case .trackFailed = $0.event { true } else { false } }
    #expect(
        mixable.events.contains { event in
            guard case .trackFailed(track.url, let problem) = event else { return false }
            return problem.message
                == "null device can't play DSD64: none of its formats at 176.4 kHz can carry DoP"
                && problem.detail.hasSuffix(
                    "it has no non-mixable 24-bit integer format at"
                        + " 176.4 kHz for DoP")
        })
    #expect(noHog.device.captured.isEmpty && mixable.device.captured.isEmpty)
}

/// With hog mode off the refusal carries the fix, and once it's on for that device, as the
/// app's fix turns it on and moves the output to the new profile, the track plays again.
@Test func theHogModeFixTurnsItOnAndThePlayAgainPlays() async throws {
    let track = try dsdTrack("fixed", bytes: 4096, seed: 4)
    let rig = try await Rig()
    rig.device.setHogModeSetting(false)
    await rig.engine.setQueue([track.url])
    await rig.engine.play()
    let failed = try await rig.wait { if case .trackFailed = $0.event { true } else { false } }
    guard case .trackFailed(_, let problem) = failed.event else { return }
    #expect(problem.fix == .turnOnHogMode(deviceUID: rig.device.deviceUID))
    try await rig.wait(for: .finished)

    rig.device.setHogModeSetting(true)
    rig.output.use(DeviceChoice(provider: rig.device, digitalVolume: false, gain: 1, formats: nil))
    await rig.engine.play(at: 0)
    try await rig.wait(for: .trackStarted(index: 0))
    try await rig.wait(for: .finished)
    let carried = try unpack(try #require(rig.device.captured.first).samples)
    #expect(
        carried.indices.map { Array(carried[$0].prefix(track.expected[$0].count)) }
            == track.expected)
}

/// DoP silence frames after the last frame of `audio` in what the device took.
private func idleFrames(after audio: [UInt8], in carried: [UInt8]) -> Int {
    (carried.count - audio.count) / 2
}

@Test func aRefusedNextTrackAndThenNoneQueueOneTailNotTwo() async throws {
    let track = try dsdTrack("last", bytes: 70_000, seed: 5)
    let missing = folder.appendingPathComponent("missing.dsf", isDirectory: false)
    // Real-time pace, so the drain's timing against the tail is a DAC's.
    let rig = try await Rig(speed: 1)
    // The engine names the missing file next, which fails, then names none.
    await rig.engine.setQueue([track.url, missing])
    await rig.engine.play()
    try await rig.wait(for: .finished)

    let carried = try unpack(rig.device.captured[0].samples)
    let tailFrames = Int(176_400 * dopTailSeconds)
    #expect(rig.events.contains { if case .trackFailed = $0 { true } else { false } })
    // The device stops a tick or so after the audio, well inside one tail; with a second tail
    // queued the drain waits out the whole first one.
    #expect(idleFrames(after: track.expected[0], in: carried[0]) < tailFrames / 2)
}

@Test func aTailIsCutForANextTrackOnAPairOfFrames() {
    // 32-bit stereo: a frame is 8 bytes, a pair 16. The tail starts at byte 1600.
    #expect(tailDiscardStart(tailStart: 1600, consumed: 800, pairBytes: 16) == 1600)
    #expect(tailDiscardStart(tailStart: 1600, consumed: 1600, pairBytes: 16) == 1600)
    // Inside the tail on an odd frame: the cut moves on to the next pair.
    #expect(tailDiscardStart(tailStart: 1600, consumed: 1608, pairBytes: 16) == 1616)
    #expect(tailDiscardStart(tailStart: 1600, consumed: 1632, pairBytes: 16) == 1632)
}
