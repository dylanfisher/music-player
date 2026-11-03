import Darwin
import Fixtures
import Foundation
import HALOutput
import Library
import LibraryBrowser
import Playback

/// The track the benchmark starts with. A fixture library file has tags but no audio, so the
/// request's own first track is swapped for this one after the library has resolved it.
private func playableTrack() throws -> URL {
    try rampAlbum(sampleRateHz: 44_100, bitsPerSample: 16, in: defaultPlaybackFixturesDirectory())
        .tracks[0]
}

/// CPU time the calling thread has used, in seconds.
private func threadCPUSeconds() -> Double {
    var info = thread_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
    let port = pthread_mach_thread_np(pthread_self())
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
        }
    }
    precondition(status == KERN_SUCCESS, "thread_info failed: \(status)")
    func seconds(_ time: time_value_t) -> Double {
        Double(time.seconds) + Double(time.microseconds) / 1e6
    }
    return seconds(info.user_time) + seconds(info.system_time)
}

/// When the first update that a track started arrived.
private final class FirstFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var nanoseconds: UInt64?
    private let started = DispatchSemaphore(value: 0)

    func note() {
        let first = lock.withLock { () -> Bool in
            guard nanoseconds == nil else { return false }
            nanoseconds = DispatchTime.now().uptimeNanoseconds
            return true
        }
        if first { started.signal() }
    }

    func wait() throws -> UInt64 {
        guard started.wait(timeout: .now() + 30) == .success else {
            throw BenchError.expected("a track to start within 30 s")
        }
        return lock.withLock { nanoseconds! }
    }
}

/// What a double-click on a row of the whole fixture library cost.
private struct PlayLatency: Sendable {
    var firstFrameMilliseconds: Double
    var mainThreadMilliseconds: Double
    var queued: Int
}

/// Clicks a row in the middle of the whole library, as the app does, and times it until the
/// output has the track's first frames. Run once, for both benchmarks.
private let playLatency = Result { () throws -> PlayLatency in
    let library = try scannedLibrary.get()
    let track = try playableTrack()
    return try onMainActor {
        let model = try await loadedModel(library.databaseURL)
        let device = NullDevice(speed: 1)
        let output = try DeviceOutput(
            DeviceChoice(provider: device, digitalVolume: false, gain: 1, formats: nil))
        defer { output.close() }
        let engine = PlaybackEngine(output: output)
        let frame = FirstFrame()
        let updates = await engine.updates()
        let listening = Task.detached {
            for await update in updates {
                if case .trackStarted = update.event { frame.note() }
            }
        }
        defer { listening.cancel() }
        let click = model.trackIDs.count / 2
        let cpuBefore = threadCPUSeconds()
        let start = DispatchTime.now().uptimeNanoseconds
        guard let playStart = try await model.playStart(selected: [], clicked: click) else {
            throw BenchError.expected("a play request for row \(click)")
        }
        let filling = await engine.play(starting: track) {
            var request = try await playStart.request()
            request.urls[request.first] = track
            return (request.urls, request.first)
        }
        let end = try frame.wait()
        let cpu = threadCPUSeconds() - cpuBefore
        try await filling.value
        let queued = await engine.state.queue.count
        guard queued == model.trackIDs.count else {
            throw BenchError.expected("\(model.trackIDs.count) tracks queued, not \(queued)")
        }
        return PlayLatency(
            firstFrameMilliseconds: Double(end - start) / 1e6, mainThreadMilliseconds: cpu * 1000,
            queued: queued)
    }
}

let playLatencyBenchmarks = [
    Benchmark(
        name: "playback: double-click to first frame, whole library queued",
        budget: Budget(appleSilicon: 25, oldMac: 100, unit: .milliseconds)
    ) {
        let latency = try playLatency.get()
        return Measured(
            value: latency.firstFrameMilliseconds,
            notes: [
                "\(latency.queued) tracks in the queue, null device, a 44.1 kHz 16-bit FLAC first"
            ])
    },
    Benchmark(
        name: "playback: main thread busy from double-click to first frame",
        budget: Budget(appleSilicon: 4, oldMac: 10, unit: .milliseconds)
    ) {
        Measured(value: try playLatency.get().mainThreadMilliseconds)
    },
]

/// What the null device's HAL steps take in the time-to-sound benchmarks. Estimates until the
/// ADI-2 checkpoint: nothing here has timed a real device's steps.
private let estimatedHALDelays = NullDevice.HALDelays(
    openSeconds: 0.01, rateChangeSeconds: 0.1, hogReleaseSeconds: 0.005)
/// The rate the device had before the app opened it, which closing a session puts back: the
/// rate macOS gives most outputs.
private let systemRateHz = 48_000.0
/// The slow simulated NAS's cost for a file the decoder reads: opening it is an operation plus
/// the median wait on the NAS's disks, and every read an operation.
private let nasFileLatency = FileLatency(
    openSeconds: slowNAS.operationSeconds + (slowNAS.fileDelay?.medianSeconds ?? 0),
    readSeconds: slowNAS.operationSeconds)
/// Runs of each case; the median is reported.
private let timeToSoundRuns = 5

/// A play action, timed while the burst track plays its silence from the call to the first IO
/// cycle that carries the sound the action asked for.
private enum SoundAction: String, CaseIterable {
    case sameRate = "double-click on a track of the same rate"
    case otherRate = "double-click on a track of another rate"
    case next = "pressing Next"
    case seekWhileFed = "seek while the track is decoded"
    case seekAfterFeed = "seek in the last seconds, after decoding moved on"
}

/// Milliseconds from the call to the first sound for each of `timeToSoundRuns` runs, each on a
/// new output.
private func timesToSound(_ action: SoundAction, latency: FileLatency?) throws -> [Double] {
    let directory = try defaultPlaybackFixturesDirectory()
    let burst = try burstTrack(in: directory).url
    let low = try rampAlbum(sampleRateHz: 44_100, bitsPerSample: 16, in: directory).tracks[0]
    let high = try rampAlbum(sampleRateHz: 96_000, bitsPerSample: 24, in: directory).tracks[0]
    return try (0..<timeToSoundRuns).map { _ in
        let device = NullDevice(speed: 1, delays: estimatedHALDelays)
        device.changeRate(to: systemRateHz)
        let output = try DeviceOutput(
            DeviceChoice(provider: device, digitalVolume: false, gain: 1, formats: nil),
            fileLatency: latency)
        defer { output.close() }
        let engine = PlaybackEngine(output: output)
        return try onMainActor {
            let started = FirstFrame()
            let updates = await engine.updates()
            let listening = Task.detached {
                for await update in updates {
                    if case .trackStarted = update.event { started.note() }
                }
            }
            defer { listening.cancel() }
            await engine.setQueue([burst, action == .next ? low : burst])
            await engine.play()
            _ = try started.wait()
            if action == .seekAfterFeed {
                // Inside the last 4 s every byte left fits the ring buffer, so once the refill
                // after the seek has run, decoding has moved on to the next track.
                await engine.seek(toSeconds: Double(BurstTrack.seconds) - 3.5)
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            device.listenForSound()
            let start = DispatchTime.now().uptimeNanoseconds
            switch action {
            case .sameRate, .otherRate:
                let track = action == .sameRate ? low : high
                _ = await engine.play(starting: track) { ([track], 0) }
            case .next:
                await engine.next()
            case .seekWhileFed, .seekAfterFeed:
                await engine.seek(toSeconds: BurstTrack.burstSeconds.lowerBound + 0.5)
            }
            guard let sound = device.soundStarted(within: 10) else {
                throw BenchError.expected("sound within 10 s of \(action.rawValue)")
            }
            return Double(sound - start) / 1e6
        }
    }
}

private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

private func milliseconds(_ values: [Double]) -> String {
    values.map { String(format: "%.1f", $0) }.joined(separator: ", ") + " ms"
}

/// A benchmark of `action` on the slow simulated NAS, with local files in its notes.
private func timeToSound(_ action: SoundAction, budget: Budget) -> Benchmark {
    Benchmark(
        name: "playback: \(action.rawValue) to its first sound, slow simulated NAS",
        budget: budget
    ) {
        let nas = try timesToSound(action, latency: nasFileLatency)
        let local = try timesToSound(action, latency: nil)
        return Measured(
            value: median(nas),
            notes: [
                "median of \(timeToSoundRuns) runs; NAS: \(milliseconds(nas))",
                String(format: "local files: median %.1f ms; ", median(local))
                    + milliseconds(local),
                "null device with estimated HAL steps: rate change "
                    + String(format: "%.0f ms", estimatedHALDelays.rateChangeSeconds * 1000)
                    + String(format: ", open %.0f ms", estimatedHALDelays.openSeconds * 1000)
                    + String(
                        format: ", hog mode release %.0f ms",
                        estimatedHALDelays.hogReleaseSeconds * 1000),
            ])
    }
}

let timeToSoundBenchmarks = [
    timeToSound(.sameRate, budget: Budget(appleSilicon: 500, oldMac: 1000, unit: .milliseconds)),
    timeToSound(.otherRate, budget: Budget(appleSilicon: 500, oldMac: 1000, unit: .milliseconds)),
    timeToSound(.next, budget: Budget(appleSilicon: 500, oldMac: 1000, unit: .milliseconds)),
    timeToSound(
        .seekWhileFed, budget: Budget(appleSilicon: 500, oldMac: 1000, unit: .milliseconds)),
    timeToSound(
        .seekAfterFeed, budget: Budget(appleSilicon: 500, oldMac: 1000, unit: .milliseconds)),
]
