import Foundation
import Testing

@testable import Fixtures
@testable import HALOutput
@testable import Playback

/// Frame `index` of `album`'s 16-bit sine as the null device's 32-bit samples.
private func frame(of album: SineAlbum, _ index: Int) -> [Int32] {
    let seconds = Double(index) / Double(album.sampleRateHz)
    return (0..<2).map { channel in
        Int32((album.value(atSeconds: seconds, channel: channel) * 32768).rounded()) << 16
    }
}

private func frame(_ samples: [Int32], _ index: Int) -> [Int32] {
    [samples[2 * index], samples[2 * index + 1]]
}

/// How many of `samples`' frames from `start` are `album`'s from `first` on, untouched.
private func untouched(
    _ samples: [Int32], from start: Int, of album: SineAlbum, from first: Int
) -> Int {
    var count = 0
    while start + count < samples.count / 2, first + count < album.trackFrames[0],
        frame(samples, start + count) == frame(of: album, first + count)
    {
        count += 1
    }
    return count
}

/// Whether `samples`' `count` frames from `start` are `album`'s from `first` on, each scaled
/// toward silence, and the last silent when `endsSilent`.
private func faded(
    _ samples: [Int32], from start: Int, count: Int, of album: SineAlbum, from first: Int,
    endsSilent: Bool = false
) -> Bool {
    let scaled = (0..<count).allSatisfy { offset in
        zip(frame(samples, start + offset), frame(of: album, first + offset)).allSatisfy {
            played, file in
            abs(Int64(played)) <= abs(Int64(file)) && (played == 0 || (played < 0) == (file < 0))
        }
    }
    return scaled && (!endsSilent || frame(samples, start + count - 1) == [0, 0])
}

/// A pause, a play and a seek on the null device: what it received is the file's samples,
/// untouched, but for a fade's worth of frames either side of each, where it moves to and from
/// silence no faster than the fade allows.
@Test func aPauseAPlayAndASeekFadeAndLeaveTheRestOfTheFileUntouched() async throws {
    let album = try sineAlbum(
        sampleRateHz: 44_100, bitsPerSample: 16, in: try defaultPlaybackFixturesDirectory())
    let fade = fadeFrames(44_100)
    let rig = try await Rig(speed: 1)
    await rig.engine.setQueue([album.tracks[0]])
    await rig.engine.play()
    try await rig.wait(for: .trackStarted(index: 0))
    try await Task.sleep(nanoseconds: 150_000_000)
    try await pause(rig)
    let pausedAt = rig.device.captured[0].samples.count / 2
    await rig.engine.play()
    try await Task.sleep(nanoseconds: 150_000_000)
    let target = 35_280
    await rig.engine.seek(toSeconds: Double(target) / 44_100)
    try await rig.wait(for: .finished)
    let samples = rig.device.captured[0].samples

    // Up to the pause, then its fade-out to silence, and silence until the device stopped.
    let before = untouched(samples, from: 0, of: album, from: 0)
    #expect(before > 4410)
    #expect(faded(samples, from: before, count: fade, of: album, from: before, endsSilent: true))
    #expect(((before + fade)..<pausedAt).allSatisfy { frame(samples, $0) == [0, 0] })

    // The play fades in from where the fade-out ended, then plays on untouched to the seek.
    #expect(faded(samples, from: pausedAt, count: fade, of: album, from: before + fade))
    let resumed = before + 2 * fade
    let played = untouched(samples, from: pausedAt + fade, of: album, from: resumed)
    #expect(played > 4410)

    // The seek fades out what played, then fades in from its target, and plays on untouched.
    let seekAt = pausedAt + fade + played
    #expect(
        faded(
            samples, from: seekAt, count: fade, of: album, from: resumed + played, endsSilent: true)
    )
    let landed = try #require(
        (seekAt + fade..<samples.count / 2).first { frame(samples, $0) != [0, 0] })
    #expect(faded(samples, from: landed, count: fade, of: album, from: target))
    #expect(
        untouched(samples, from: landed + fade, of: album, from: target + fade)
            == album.trackFrames[0] - target - fade)

    // The sine's own steepest step, plus the most a step of the fade adds, plus rounding. From
    // the second frame to the file's last: the sine starts and ends at full level.
    let end = landed + album.trackFrames[0] - target
    let amplitude = 0.5
    let sineStep: Double = amplitude * 2 * .pi * 997 / 44_100
    let allowed = sineStep + amplitude / Double(fade) + 1e-4
    var steepest = 0.0
    for index in 2..<2 * end {
        let step = abs(Double(samples[index]) - Double(samples[index - 2])) / Double(1 << 31)
        steepest = max(steepest, step)
    }
    #expect(steepest <= allowed, "steepest step \(steepest), allowed \(allowed)")
    #expect(!rig.events.contains { if case .underrun = $0 { true } else { false } })
}
