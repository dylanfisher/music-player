import Darwin
import DisplayText
import Fixtures
import Foundation
import HALOutput
import Library
import Playback
import SQLite
import Settings

/// How long the soak plays. `scripts/bench --soak <seconds>` sets it; the hour the budget is for
/// is too long for every run.
nonisolated(unsafe) var soakSeconds = 20.0

/// How often the soak scans the fixture library, from its start.
private let soakScanIntervalSeconds = 300.0

/// When the soak's memory counts from: one scan interval in, or a quarter of a shorter soak,
/// once the first scan's database and caches have settled.
private var soakSettledSeconds: Double { min(soakScanIntervalSeconds, soakSeconds / 4) }

/// How long after each scan ends its memory is sampled: the trough of the cycle, the same
/// point in each, so growth compares like with like rather than a scan's peak with an idle end.
private let soakTroughDelaySeconds = soakScanIntervalSeconds / 10

/// What a soak under load measured.
private struct LoadedSoak {
    var underrunFrames: Int
    var scans: Int
    var searches: Int
    /// The footprint `soakTroughDelaySeconds` after each scan that ended once settled.
    var troughsMB: [Double]
    var settledMB: Double
    var endMB: Double
    var peakMB: Double

    /// The last trough less the first, or, in a soak too short for two, the end less the settle
    /// point.
    var growthMB: Double {
        troughsMB.count >= 2 ? troughsMB.last! - troughsMB.first! : endMB - settledMB
    }
}

/// Plays on repeat for `soakSeconds` while a full scan into a new index runs every 5 minutes and
/// a search every second, the load a first scan of the NAS puts beside playback. Each scan and
/// the search have their own connections, as in the app. Run once, for both soak benchmarks.
private let loadedSoak = Result { () throws -> LoadedSoak in
    let library = try scannedLibrary.get()
    let queries = try typedQueries(library.index)
    let directory = try defaultPlaybackFixturesDirectory()
    let queue =
        [try hiResTrack(in: directory)]
        + (try rampAlbum(sampleRateHz: 44_100, bitsPerSample: 16, in: directory)).tracks
        + (try rampAlbum(sampleRateHz: 96_000, bitsPerSample: 24, in: directory)).tracks
    return try withScratchDirectory("soak") { scratch in
        try playing(queue, speed: 1, repeatMode: .all) { session in
            let load = SoakLoad(
                folder: library.folder, scratch: scratch, searchDatabase: library.databaseURL,
                queries: queries)
            let start = DispatchTime.now().uptimeNanoseconds
            func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9 }
            var settledMB: Double?
            var peakMB = 0.0
            var troughsMB: [Double] = []
            var sampledScans = 0
            while elapsed() < soakSeconds {
                let current = try footprintMB()
                peakMB = max(peakMB, current)
                if settledMB == nil, elapsed() >= soakSettledSeconds { settledMB = current }
                let ends = load.scanEnds
                while sampledScans < ends.count,
                    elapsed() >= ends[sampledScans] + soakTroughDelaySeconds
                {
                    if ends[sampledScans] >= soakSettledSeconds { troughsMB.append(current) }
                    sampledScans += 1
                }
                if let failure = load.failure { throw failure }
                Thread.sleep(forTimeInterval: 1)
            }
            let (scans, searches) = try load.stop()
            let endMB = try footprintMB()
            return LoadedSoak(
                underrunFrames: session.underrunFrames(), scans: scans, searches: searches,
                troughsMB: troughsMB, settledMB: try settledMB ?? footprintMB(), endMB: endMB,
                peakMB: max(peakMB, endMB))
        }
    }
}

/// The soak's load: one thread scanning, one searching, until stopped.
private final class SoakLoad: @unchecked Sendable {
    // Guarded by `lock`.
    private let lock = NSLock()
    private var running = true
    private var scans = 0
    /// Seconds from the start at which each scan ended.
    private var ends: [Double] = []
    private var searches = 0
    private var firstFailure: (any Error)?
    private let done = DispatchGroup()
    private let start = DispatchTime.now().uptimeNanoseconds

    init(folder: WatchedFolder, scratch: URL, searchDatabase: URL, queries: [String]) {
        loop(every: soakScanIntervalSeconds) { [self] in
            let databaseURL = scratch.appendingPathComponent("scan.sqlite")
            for suffix in ["", Database.walSuffix, Database.shmSuffix] {
                let url = URL(fileURLWithPath: databaseURL.path + suffix)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
            let summary = try LibraryScanner(databaseURL: databaseURL).scan(folder)
            guard summary.read == fullLibraryFileCount, summary.issues.isEmpty else {
                throw BenchError.expected("each soak scan to read every file: \(summary)")
            }
            let end = elapsed()
            lock.withLock {
                scans += 1
                ends.append(end)
            }
        }
        var index: LibraryIndex?
        loop(every: 1) { [self] in
            let connection = try index ?? LibraryIndex(at: searchDatabase)
            index = connection
            let text = lock.withLock { queries[searches % queries.count] }
            _ = try connection.trackIDs(TrackFilter(search: text), sortedBy: .artist)
            lock.withLock { searches += 1 }
        }
    }

    var failure: (any Error)? { lock.withLock { firstFailure } }
    var scanEnds: [Double] { lock.withLock { ends } }

    private func elapsed() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    /// Runs `body` on its own thread at 0, `interval`, 2 × `interval` and so on, until stopped.
    private func loop(every interval: Double, _ body: @escaping () throws -> Void) {
        done.enter()
        nonisolated(unsafe) let body = body
        Thread.detachNewThread { [self] in
            var next = 0.0
            while lock.withLock({ running && firstFailure == nil }) {
                if elapsed() >= next {
                    do {
                        try body()
                    } catch {
                        lock.withLock { firstFailure = firstFailure ?? error }
                    }
                    next += interval
                }
                usleep(50_000)
            }
            done.leave()
        }
    }

    /// Waits for a scan under way to finish, and returns how many scans and searches ran.
    func stop() throws -> (scans: Int, searches: Int) {
        lock.withLock { running = false }
        done.wait()
        return try lock.withLock {
            if let firstFailure { throw firstFailure }
            return (scans, searches)
        }
    }
}

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
            notes.append("\(kilohertz(Double(rate))) kHz \(bitDepth(bits)): \(gap) samples")
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
        name: "playback: underruns in a soak under load",
        budget: Budget(appleSilicon: 0, oldMac: 0, unit: .frames)
    ) {
        let soak = try loadedSoak.get()
        return Measured(
            value: Double(soak.underrunFrames),
            notes: [
                String(
                    format: "%.0f s, 24/192 then 44.1 and 96 kHz albums on repeat; "
                        + "./scripts/bench --soak 3600 for the hour", soakSeconds),
                "under load: \(soak.scans) full scans of the fixture library into a new index,"
                    + String(format: " one every %.0f s,", soakScanIntervalSeconds)
                    + " and \(soak.searches) searches, one a second",
            ])
    },
    Benchmark(
        name: "playback: memory growth in a soak under load, between scan troughs",
        budget: Budget(appleSilicon: 10, oldMac: 10, unit: .megabytes)
    ) {
        let soak = try loadedSoak.get()
        let troughs = soak.troughsMB.map { String(format: "%.1f", $0) }.joined(separator: ", ")
        return Measured(
            value: soak.growthMB,
            notes: [
                soak.troughsMB.count >= 2
                    ? String(
                        format: "footprint %.0f s after each scan that ended past %.0f s: %@ MB",
                        soakTroughDelaySeconds, soakSettledSeconds, troughs)
                    : String(
                        format: "too short for two scan troughs: %.1f MB at %.0f s, %.1f MB at"
                            + " the end", soak.settledMB, soakSettledSeconds, soak.endMB),
                String(format: "peak %.1f MB", soak.peakMB),
            ])
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
    let output = try DeviceOutput(
        DeviceChoice(provider: device, digitalVolume: false, gain: 1, formats: nil))
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
