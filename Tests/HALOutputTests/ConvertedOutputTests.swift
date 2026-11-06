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
    #expect(changes.map(\.to) == ["null device: 48 kHz · 32-bit float, converted"])
    #expect(rig.device.openSessionCount == 0)
}

@Test func seekingAConvertedTrackLandsOnTheFilesTime() async throws {
    let album = try sineAlbum(44_100, 16)
    let rig = try await Rig(speed: 1, formats: NullDevice.float48k)
    await rig.engine.setQueue([album.tracks[0]])
    await rig.engine.play()
    try await rig.wait(for: .trackStarted(index: 0))
    try await Task.sleep(nanoseconds: 100_000_000)
    try await pause(rig)
    // Stopped, the position is what the IO proc took, counted at the device's rate.
    let pulled = frames(rig.device.captured[0]).count
    let stopped = try #require(await rig.engine.position())
    let taken = framesTaken(rig.device.captured[0].samples, float: true)
    #expect(abs(stopped - Double(taken) / deviceRateHz) < 1e-6)

    await rig.engine.seek(toSeconds: 0.5)
    try await Task.sleep(nanoseconds: 50_000_000)
    let paused = try #require(await rig.engine.position())
    #expect(abs(paused - 0.5) < 0.001)
    await rig.engine.play()
    try await rig.wait(for: .finished)

    // After what played before the pause, the sine carries on from half a second in, once the
    // play's fade-in is over.
    let played = frames(rig.device.captured[0])
    let remaining = Int(((Double(album.trackFrames[0]) / 44_100 - 0.5) * deviceRateHz).rounded(.up))
    try #require(played.count >= pulled + remaining)
    let settled = pulled + max(edgeFrames, fadeFrames(deviceRateHz))
    #expect(
        largestError(
            played, album, from: pulled, atSeconds: 0.5,
            settled..<(pulled + remaining - edgeFrames)) < tolerance)
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

// MARK: Channels

/// The frames in the middle of a run, away from where a steady level starts and stops.
private func middle<T>(_ frames: [T], dropping edge: Int = 2_000) -> ArraySlice<T> {
    frames[edge..<(frames.count - edge)]
}

/// What the device takes, without its trailing silence.
private func audioFrames(_ run: NullDevice.CapturedRun) -> [(Double, Double)] {
    var played = frames(run)
    while let last = played.last, last == (0, 0) { played.removeLast() }
    return played
}

@Test func aMonoTrackPlaysOnBothChannelsOfAStereoDevice() async throws {
    let track = try levelTrack(channels: 1, in: try defaultPlaybackFixturesDirectory())
    let rig = try await Rig(formats: NullDevice.float48k)
    await rig.engine.setQueue([track])
    await rig.engine.play()
    try await rig.wait(for: .finished)
    let played = audioFrames(rig.device.captured[0])
    try #require(played.count > 20_000)
    #expect(
        middle(played).allSatisfy { abs($0.0 - levelOf(0)) < 1e-4 && abs($0.1 - levelOf(0)) < 1e-4 }
    )
}

/// The stereo levels channels holding `levels`, in the WAV and FLAC default order, downmix to.
private func downmixedLevels(_ levels: [Double]) throws -> (Double, Double) {
    let mix = try channelMix(
        from: ChannelOrder(defaultFor: levels.count, isAssumed: false).roles, to: 2)
    func side(_ output: Int) -> Double {
        levels.indices.reduce(0) { $0 + Double(mix[output * levels.count + $1]) * levels[$1] }
    }
    return (side(0), side(1))
}

/// The stereo levels a `levelTrack` of `channels` downmixes to.
private func downmixedLevels(_ channels: Int) throws -> (Double, Double) {
    try downmixedLevels((0..<channels).map(levelOf))
}

/// The stereo levels the float-only device plays `track` at, once steady.
private func playedLevels(_ track: URL) async throws -> [(Double, Double)] {
    let rig = try await Rig(formats: NullDevice.float48k)
    await rig.engine.setQueue([track])
    await rig.engine.play()
    try await rig.wait(for: .finished)
    let played = audioFrames(rig.device.captured[0])
    try #require(played.count > 20_000)
    return Array(middle(played))
}

@Test func aFivePointOneTrackIsDownmixedForAStereoDevice() async throws {
    let track = try levelTrack(channels: 6, in: try defaultPlaybackFixturesDirectory())
    let rig = try await Rig(formats: NullDevice.float48k)
    let paths = Collected(rig.output.signalPaths)
    await rig.engine.setQueue([track])
    await rig.engine.play()
    try await rig.wait(for: .finished)
    let (left, right) = try downmixedLevels(6)
    // The centre, the surrounds and none of the LFE: more than front left and right alone.
    #expect(left > levelOf(0) && right > levelOf(1))
    let played = audioFrames(rig.device.captured[0])
    try #require(played.count > 20_000)
    #expect(middle(played).allSatisfy { abs($0.0 - left) < 1e-4 && abs($0.1 - right) < 1e-4 })
    var downmixed = false
    while !downmixed {
        let path = try await paths.next()
        guard let signal = path.track else { continue }
        if case .changed(let changes) = signalVerdict(path) {
            downmixed = changes.contains(.decoderRemixes(fromChannels: 6, toChannels: 2))
            // FLAC states its order.
            #expect(!changes.contains(.channelOrderAssumed))
        }
        #expect(signal.decoded.channels == 2)
    }
}

/// afconvert's arguments for a 5.1 file in `codec`, which stores C L R Ls Rs LFE, from levels in
/// the WAV order.
private func fivePointOne(_ codec: String, layout: String) -> [String] {
    ["-f", "m4af", "-d", codec, "-l", "MPEG_5_1_A", "-l", layout]
}

@Test(arguments: [("alac", "MPEG_5_1_D", 1e-4), ("aac", "AAC_5_1", 2e-3)])
func anALACOrAACFivePointOneTrackIsDownmixedFromItsOwnChannelOrder(
    codec: String, layout: String, tolerance: Double
) async throws {
    let directory = try defaultPlaybackFixturesDirectory()
    // Only the centre: it lands on both sides equally, not on the left alone.
    let centre = try levelTrack(
        named: "centre-\(codec)-6ch.m4a", levels: [0, 0, 0.5, 0, 0, 0],
        afconvert: fivePointOne(codec, layout: layout), in: directory)
    let (centreLeft, centreRight) = try downmixedLevels([0, 0, 0.5, 0, 0, 0])
    #expect(centreLeft == centreRight && centreLeft > 0.2)
    #expect(
        try await playedLevels(centre).allSatisfy {
            abs($0.0 - centreLeft) < tolerance && abs($0.1 - centreRight) < tolerance
        })
    // Every channel where its role puts it.
    let levels = (0..<6).map(levelOf)
    let all = try levelTrack(
        named: "\(codec)-6ch.m4a", levels: levels,
        afconvert: fivePointOne(codec, layout: layout), in: directory)
    let (left, right) = try downmixedLevels(levels)
    #expect(
        try await playedLevels(all).allSatisfy {
            abs($0.0 - left) < tolerance && abs($0.1 - right) < tolerance
        })
}

@Test func aWAVWithoutAChannelMaskIsDownmixedInTheDefaultOrderAndSaysSo() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "converted-output-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let wav = directory.appendingPathComponent("levels-6ch.wav")
    try writeWAV(at: wav, sampleRateHz: 44_100, bitsPerSample: 24, channels: 6, frames: 22_050) {
        _, channel in Int32((levelOf(channel) * Double(1 << 23)).rounded())
    }
    let rig = try await Rig(formats: NullDevice.float48k)
    let paths = Collected(rig.output.signalPaths)
    await rig.engine.setQueue([wav])
    await rig.engine.play()
    try await rig.wait(for: .finished)
    let (left, right) = try downmixedLevels(6)
    let played = audioFrames(rig.device.captured[0])
    try #require(played.count > 20_000)
    #expect(middle(played).allSatisfy { abs($0.0 - left) < 1e-4 && abs($0.1 - right) < 1e-4 })
    while true {
        let path = try await paths.next()
        guard let signal = path.track, case .changed(let changes) = signalVerdict(path) else {
            continue
        }
        #expect(signal.channelOrderAssumed)
        #expect(changes.contains(.channelOrderAssumed))
        return
    }
}

@Test func aDeepMultichannelTrackKeepsItsDepthOnTheADI2() async throws {
    // The ADI-2's 2 ch 32-bit integer format, beside an 8 ch 16-bit one.
    let formats = DeviceFormats(
        sampleRatesHz: [44_100...192_000],
        formats: [
            PhysicalFormat(
                formatID: linearPCMFormatID, sampleRateHz: 44_100...192_000, bitsPerChannel: 32,
                channels: 2, isFloat: false, isMixable: false),
            PhysicalFormat(
                formatID: linearPCMFormatID, sampleRateHz: 44_100...192_000, bitsPerChannel: 16,
                channels: 8, isFloat: false, isMixable: false),
        ])
    let track = try levelTrack(channels: 6, in: try defaultPlaybackFixturesDirectory())
    let rig = try await Rig(formats: formats)
    await rig.engine.setQueue([track])
    await rig.engine.play()
    try await rig.wait(for: .finished)
    let run = rig.device.captured[0]
    #expect(run.sampleRateHz == 44_100)
    let (left, right) = try downmixedLevels(6)
    let scale = Double(1 << 31)
    var played = stride(from: 0, to: run.samples.count - 1, by: 2).map {
        (Double(run.samples[$0]) / scale, Double(run.samples[$0 + 1]) / scale)
    }
    while let last = played.last, last == (0, 0) { played.removeLast() }
    #expect(middle(played).allSatisfy { abs($0.0 - left) < 1e-6 && abs($0.1 - right) < 1e-6 })
}

// MARK: Joins, seeks and the next track

/// Frames of `album`'s first track at the device's rate: where the second starts.
private func joinFrame(_ album: SineAlbum, from frame: Int = 0) -> Int {
    Int(
        (Double(album.trackFrames[0] - frame) * deviceRateHz / Double(album.sampleRateHz))
            .rounded(.up))
}

@Test func theNextTrackStartsOnItsFirstConvertedFrame() async throws {
    let album = try sineAlbum(44_100, 16)
    let rig = try await Rig(speed: 1, formats: NullDevice.float48k)
    await rig.engine.setQueue(album.tracks)
    await rig.engine.play()
    try await rig.wait(for: .trackStarted(index: 1))
    try await pause(rig)
    let taken = framesTaken(rig.device.captured[0].samples, float: true)
    let position = try #require(await rig.engine.position())
    // Announced once the device had taken the join, and counted from it.
    #expect(taken >= joinFrame(album))
    #expect(abs(position - Double(taken - joinFrame(album)) / deviceRateHz) < 1e-6)
}

@Test func aDoubleClickWhileConvertingRestartsTheConverterOnTheOpenDevice() async throws {
    let album = try sineAlbum(44_100, 16)
    let rig = try await Rig(speed: 1, formats: NullDevice.float48k)
    await rig.engine.setQueue([album.tracks[0]])
    await rig.engine.play()
    try await rig.wait(for: .trackStarted(index: 0))
    try await Task.sleep(nanoseconds: 100_000_000)
    try await pause(rig)
    let pulled = frames(rig.device.captured[0]).count
    let second = album.tracks[1]
    let filling = await rig.engine.play(starting: second) { ([second], 0) }
    try await filling.value
    try await rig.wait(for: .finished)

    #expect(rig.device.openedSessionCount == 1)
    #expect(rig.device.captured.count == 1)
    // The second track's sine from its start, straight after what played of the first.
    let played = frames(rig.device.captured[0])
    let remaining = Int(
        (Double(album.trackFrames[1]) * deviceRateHz / Double(album.sampleRateHz)).rounded(.up))
    try #require(played.count >= pulled + remaining)
    let start = Double(album.trackFrames[0]) / Double(album.sampleRateHz)
    #expect(
        largestError(
            played, album, from: pulled, atSeconds: start,
            (pulled + edgeFrames)..<(pulled + remaining - edgeFrames)) < tolerance)
}

@Test func aSeekNearTheEndCarriesOnAcrossTheJoin() async throws {
    let album = try sineAlbum(44_100, 16)
    let rig = try await Rig(speed: 1, formats: NullDevice.float48k)
    await rig.engine.setQueue(album.tracks)
    await rig.engine.play()
    try await rig.wait(for: .trackStarted(index: 0))
    try await pause(rig)
    let before = frames(rig.device.captured[0]).count
    // The second track is already queued in the converter, well inside the last 4 s.
    await rig.engine.seek(toSeconds: 0.8)
    await rig.engine.play()
    try await rig.wait(for: .trackStarted(index: 1))
    try await pause(rig)
    let played = frames(rig.device.captured[0])
    let taken = framesTaken(rig.device.captured[0].samples, float: true)
    let join = before + joinFrame(album, from: 35_280)
    let position = try #require(await rig.engine.position())
    #expect(abs(position - Double(taken - join) / deviceRateHz) < 1e-6)
    // Between the play's fade-in and the pause's fade-out.
    let fade = fadeFrames(deviceRateHz)
    #expect(
        largestError(
            played, album, from: before, atSeconds: 0.8,
            (before + max(edgeFrames, fade))..<(taken - fade)) < tolerance)
}

/// The output on its own, with each item's id its index in `urls`.
private func directOutput(_ device: NullDevice) throws -> (DeviceOutput, Collected<OutputEvent>) {
    let output = try DeviceOutput(
        DeviceChoice(provider: device, digitalVolume: false, gain: 1, formats: nil))
    return (output, Collected(output.events))
}

private func waitFor(
    _ events: Collected<OutputEvent>, _ matches: (OutputEvent) -> Bool
) async throws {
    while !matches(try await events.next()) {}
}

/// The first track ends 26 frames past the ring buffer's capacity, in the 53 frames the converter
/// holds back: when the ring buffer is full, the track's last frames are in the converter or the
/// decode chunk, not the ring buffer. 2^22 bytes of 48 kHz stereo float is 8 s.
private func slightlyOverFullAlbum() throws -> (album: SineAlbum, capacity: Int, join: Int) {
    let capacity = 1 << 22 / 8
    let firstFrames = Int((Double(capacity + 26) * 44_100 / deviceRateHz).rounded(.down))
    let album = try sineAlbum(
        sampleRateHz: 44_100, bitsPerSample: 16, firstTrackFrames: firstFrames,
        in: try defaultPlaybackFixturesDirectory())
    let join = joinFrame(album)
    try #require(join > capacity && join - capacity < 50)
    return (album, capacity, join)
}

@Test func replacingAConvertedNextTrackKeepsAllOfTheCurrentOne() async throws {
    let (album, _, join) = try slightlyOverFullAlbum()
    let device = NullDevice(speed: 8, keepsSamples: true)
    device.report(NullDevice.float48k)
    let (output, events) = try directOutput(device)
    defer { output.close() }
    // Named together with the load, the second track is fed into the converter while the first
    // is decoded, so when the ring buffer is full the first track's last frames are in the
    // decode chunk, decoded with the second track's start after them.
    output.load(
        OutputItem(id: 0, url: album.tracks[0]), next: OutputItem(id: 1, url: album.tracks[1]),
        startSeconds: 0, playing: false)
    // Stopped, it decodes until the ring buffer is full.
    try await Task.sleep(nanoseconds: 3_000_000_000)
    output.setNext(OutputItem(id: 2, url: album.tracks[0]))
    output.play()
    try await waitFor(events) { if case .finished(2) = $0 { true } else { false } }

    let played = frames(device.captured[0])
    try #require(played.count > 2 * join)
    #expect(largestError(played, album, from: 0, atSeconds: 0, edgeFrames..<join) < tolerance)
    #expect(
        largestError(
            played, album, from: join, atSeconds: 0, (join + edgeFrames)..<(2 * join - edgeFrames)
        ) < tolerance)
    #expect(!events.returned.contains { if case .trackStarted(1, _) = $0 { true } else { false } })
}

@Test func replacingANextTrackNamedAfterTheDecodeEndedFlushesTheConverter() async throws {
    let (album, _, join) = try slightlyOverFullAlbum()
    let device = NullDevice(speed: 8, keepsSamples: true)
    device.report(NullDevice.float48k)
    let (output, events) = try directOutput(device)
    defer { output.close() }
    output.load(OutputItem(id: 0, url: album.tracks[0]), startSeconds: 0, playing: false)
    // Stopped, it decodes the whole first track, and the converter holds back its last frames.
    // Fed a second track then, nothing of it is decoded until the ring buffer drains, so the
    // replacement flushes the converter: the first track ends in a few frames' ring and a frame
    // short of where the join was counted.
    try await Task.sleep(nanoseconds: 3_000_000_000)
    output.setNext(OutputItem(id: 1, url: album.tracks[1]))
    output.setNext(OutputItem(id: 2, url: album.tracks[0]))
    output.play()
    try await waitFor(events) { if case .finished(2) = $0 { true } else { false } }

    let played = frames(device.captured[0])
    try #require(played.count > 2 * join - 2)
    #expect(
        largestError(played, album, from: 0, atSeconds: 0, edgeFrames..<(join - edgeFrames))
            < tolerance)
    let best = (-1...0).map { offset in
        largestError(
            played, album, from: join + offset, atSeconds: 0,
            (join + edgeFrames)..<(2 * join - edgeFrames - 1))
    }.min()!
    #expect(best < tolerance)
    #expect(!events.returned.contains { if case .trackStarted(1, _) = $0 { true } else { false } })
}

@Test func aNextTrackNamedInTheLastHalfSecondFollowsWithoutAGap() async throws {
    let album = try sineAlbum(44_100, 16)
    let device = NullDevice(speed: 1, keepsSamples: true)
    device.report(NullDevice.float48k)
    let (output, events) = try directOutput(device)
    defer { output.close() }
    output.load(OutputItem(id: 0, url: album.tracks[0]), startSeconds: 0, playing: true)
    let deadline = Date().addingTimeInterval(10)
    while (output.position()?.seconds ?? 0) < 0.65 {
        try #require(Date() < deadline, "the first track never got past 0.65 s")
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    output.setNext(OutputItem(id: 1, url: album.tracks[1]))
    try await waitFor(events) { if case .finished(1) = $0 { true } else { false } }

    let played = frames(device.captured[0])
    let join = joinFrame(album)
    #expect(
        largestError(played, album, from: 0, atSeconds: 0, edgeFrames..<(join - edgeFrames))
            < tolerance)
    // The converter was flushed, so the second track starts a new one: a seam, but no gap.
    let second = Double(album.trackFrames[0]) / 44_100
    let length = Int((Double(album.trackFrames[1]) * deviceRateHz / 44_100).rounded(.up))
    let best = (-1...1).map { offset in
        largestError(
            played, album, from: join + offset, atSeconds: second,
            (join + edgeFrames)..<(join + length - edgeFrames))
    }.min()!
    #expect(best < tolerance)
}

private func deviceState(_ path: SignalPath) -> DeviceState {
    switch path.sink {
    case .device(let sink): sink.state
    case .renderer: .unreadable("a device output published a renderer")
    }
}
