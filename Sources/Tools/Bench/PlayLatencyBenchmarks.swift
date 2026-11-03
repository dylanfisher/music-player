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
