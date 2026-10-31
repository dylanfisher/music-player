import Darwin
import DisplayText
import Fixtures
import Foundation
import HALOutput
import Playback

/// How long the soak plays. `scripts/bench --soak <seconds>` sets it; the hour the budget is for
/// is too long for every run.
nonisolated(unsafe) var soakSeconds = 20.0

/// How long the CPU benchmark plays, after a warm-up.
private let cpuSeconds = 30.0

let playbackBenchmarks = [
    Benchmark(
        name: "playback: CPU while playing 24/192 FLAC",
        budget: Budget(appleSilicon: 3, oldMac: 5, unit: .percentOfCore)
    ) {
        let track = try hiResTrack(in: try defaultPlaybackFixturesDirectory())
        let (percent, underruns) = try cpuPercent(playing: track, speed: 1, for: cpuSeconds)
        // At real-time pace the work comes in short bursts the CPU runs at a low clock; run flat
        // out, the same work shows what decoding itself costs.
        let (fast, _) = try cpuPercent(playing: track, speed: 20, for: 5)
        return Measured(
            value: percent,
            notes: [
                String(format: "%.0f s through the null device at real-time pace", cpuSeconds),
                "underruns: \(underruns) frames",
                String(
                    format: "%.2f percent of a core per second of audio when decoding flat out",
                    fast / 20),
            ])
    },
    Benchmark(
        name: "playback: gap between same-format tracks",
        budget: Budget(appleSilicon: 0, oldMac: 0, unit: .samples)
    ) {
        let directory = try defaultPlaybackFixturesDirectory()
        var worst = 0
        var notes: [String] = []
        for (rate, bits) in [(44_100, 16), (96_000, 24)] {
            let album = try rampAlbum(sampleRateHz: rate, bitsPerSample: bits, in: directory)
            let gap = try playing(album.tracks, speed: 4, keepsSamples: true) { session in
                session.waitUntilFinished()
                return try gapFrames(album, in: session.device.captured)
            }
            worst = max(worst, gap)
            notes.append("\(kilohertz(Double(rate))) kHz \(bits)-bit: \(gap) samples")
        }
        return Measured(value: Double(worst), notes: notes)
    },
    Benchmark(
        name: "playback: track change that switches sample rate",
        budget: Budget(appleSilicon: 500, oldMac: 500, unit: .milliseconds)
    ) {
        let directory = try defaultPlaybackFixturesDirectory()
        let low = try rampAlbum(sampleRateHz: 44_100, bitsPerSample: 16, in: directory)
        let high = try rampAlbum(sampleRateHz: 96_000, bitsPerSample: 24, in: directory)
        let queue = [low.tracks[1], high.tracks[1], low.tracks[1], high.tracks[1]]
        let changes = try playing(queue, speed: 1) { session in
            session.waitUntilFinished()
            return Array(session.formatChanges().dropFirst())
        }
        let switches = changes.compactMap { $0.switchSeconds.map { $0 * 1000 } }
        let slowest = changes.max { ($0.switchSeconds ?? 0) < ($1.switchSeconds ?? 0) }
        let steps = (slowest?.steps ?? []).map {
            String(format: "%@ %.1f ms", $0.name, $0.seconds * 1000)
        }
        guard switches.count == queue.count - 1 else {
            throw BenchError.expected("\(queue.count - 1) rate switches, not \(switches.count)")
        }
        return Measured(
            value: switches.max()!,
            notes: [
                "switches: "
                    + switches.map { String(format: "%.0f ms", $0) }.joined(separator: ", "),
                "slowest: " + steps.joined(separator: ", "),
                "from the old track's last sample played to the new one's first queued; the real"
                    + " device adds setting its rate and format",
            ])
    },
    Benchmark(
        name: "playback: underruns in a soak",
        budget: Budget(appleSilicon: 0, oldMac: 0, unit: .frames)
    ) {
        let directory = try defaultPlaybackFixturesDirectory()
        let queue =
            [try hiResTrack(in: directory)]
            + (try rampAlbum(sampleRateHz: 44_100, bitsPerSample: 16, in: directory)).tracks
            + (try rampAlbum(sampleRateHz: 96_000, bitsPerSample: 24, in: directory)).tracks
        return try playing(queue, speed: 1, repeatMode: .all) { session in
            Thread.sleep(forTimeInterval: soakSeconds)
            return Measured(
                value: Double(session.underrunFrames()),
                notes: [
                    String(
                        format: "%.0f s, 24/192 then 44.1 and 96 kHz albums on repeat; "
                            + "./scripts/bench --soak 3600 for the hour", soakSeconds)
                ])
        }
    },
]

/// CPU time over wall time while `track` plays on repeat, after a warm-up, and the underrun
/// frames meanwhile.
private func cpuPercent(playing track: URL, speed: Double, for duration: Double) throws -> (
    Double, Int
) {
    try playing([track], speed: speed, repeatMode: .all) { session in
        Thread.sleep(forTimeInterval: 2)
        let start = cpuTimeSeconds()
        let wall = seconds { Thread.sleep(forTimeInterval: duration) }
        return ((cpuTimeSeconds() - start) / wall * 100, session.underrunFrames())
    }
}

/// User and system CPU time this process has used.
private func cpuTimeSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

/// An engine playing through `DeviceOutput` on a null device, and every update it published.
private final class Session: @unchecked Sendable {
    let device: NullDevice
    private let lock = NSLock()
    private var updates: [PlaybackUpdate] = []
    private let finished = DispatchSemaphore(value: 0)

    init(device: NullDevice) { self.device = device }

    func record(_ update: PlaybackUpdate) {
        lock.withLock { updates.append(update) }
        if update.event == .finished { finished.signal() }
    }

    func waitUntilFinished() { finished.wait() }

    func underrunFrames() -> Int {
        lock.withLock {
            updates.reduce(0) { total, update in
                if case .underrun(let frames) = update.event { total + frames } else { total }
            }
        }
    }

    func formatChanges() -> [FormatChange] {
        lock.withLock {
            updates.compactMap { update in
                if case .formatChanged(let change) = update.event { change } else { nil }
            }
        }
    }

    func failures() -> [String] {
        lock.withLock {
            updates.compactMap { update in
                switch update.event {
                case .trackFailed(let url, let reason): "\(url.lastPathComponent): \(reason)"
                case .failed(let reason): reason
                default: nil
                }
            }
        }
    }
}

/// Plays `queue` on a null device for as long as `body` runs, then closes the output.
private func playing<T>(
    _ queue: [URL], speed: Double, keepsSamples: Bool = false, repeatMode: RepeatMode = .off,
    _ body: (Session) throws -> T
) throws -> T {
    let device = NullDevice(speed: speed, keepsSamples: keepsSamples)
    let output = try DeviceOutput(provider: device, digitalVolume: false)
    let engine = PlaybackEngine(output: output)
    let session = Session(device: device)
    let started = DispatchSemaphore(value: 0)
    let listening = Task.detached {
        let updates = await engine.updates()
        await engine.setRepeat(repeatMode)
        await engine.setQueue(queue)
        await engine.play()
        started.signal()
        for await update in updates { session.record(update) }
    }
    started.wait()
    let result = Result { try body(session) }
    output.close()
    listening.cancel()
    if let failure = session.failures().first {
        throw BenchError.expected("playback, not \(failure)")
    }
    return try result.get()
}

/// Samples missing or added where the album's tracks meet: 0 when the capture holds the whole
/// ramp unbroken from its first frame.
private func gapFrames(_ album: RampAlbum, in runs: [NullDevice.CapturedRun]) throws -> Int {
    guard runs.count == 1, let samples = runs.first?.samples else {
        throw BenchError.expected("one run at one rate, not \(runs.count)")
    }
    func matches(_ index: Int, _ frame: Int) -> Bool {
        let (left, right) = album.frame(frame)
        return 2 * index + 1 < samples.count && samples[2 * index] == left
            && samples[2 * index + 1] == right
    }
    guard let start = (0..<samples.count / 2).first(where: { matches($0, 0) }) else {
        throw BenchError.expected("the album's first frame in the capture")
    }
    var frame = 0
    while frame < album.totalFrames, matches(start + frame, frame) { frame += 1 }
    if frame == album.totalFrames { return 0 }
    // The ramp broke at `frame`: find where it picks up again.
    guard let resumed = (start + frame..<samples.count / 2).first(where: { matches($0, frame) })
    else { throw BenchError.expected("the album to continue after frame \(frame)") }
    return resumed - (start + frame)
}
