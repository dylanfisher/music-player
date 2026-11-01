import CoreAudio
import DisplayText
import Foundation
import HALRender
import Log
import Metadata
import Playback
import RingBuffer

private let logger = moduleLogger()

enum DeviceOutputError: Error, CustomStringConvertible {
    case outOfMemory
    case noVolumeForFormat(String)
    /// The file's audio stopped well before the length its header gives, as a partial file's
    /// or one cut short while it played does.
    case endedEarly(atSeconds: Double, ofSeconds: Double)
    /// No rate or format the device reported carries the track unchanged.
    case deviceCannotTake(device: String, sampleRateHz: Double, channels: UInt32, DeviceFormats)

    var description: String {
        switch self {
        case .outOfMemory: "couldn't allocate the playback buffer"
        case .endedEarly(let at, let length):
            String(format: "the audio ends at %.1f s of %.1f s; the file is cut short", at, length)
        case .noVolumeForFormat(let format):
            "the digital volume can't scale samples in this device format: \(format)"
        case .deviceCannotTake(let device, let rate, let channels, let formats):
            "\(device) can't take \(channels)-channel audio at \(kilohertz(rate)) kHz; it offers"
                + " \(formats.sampleRatesHz.map(kilohertz).joined(separator: ", ")) kHz"
        }
    }
}

/// Plays tracks bit-perfect on the device a `PCMDeviceProvider` finds, as an `Output`.
///
/// One control thread does everything except the IO proc. It decodes ahead into a ring buffer the
/// IO proc reads, and records where each track starts as a position in the count of bytes
/// written. The IO proc's count of bytes consumed then says when a track has really started. A
/// next track with the same rate and channel count is decoded straight after the current one, so
/// there is no gap and the device isn't touched. One that differs waits until the ring buffer has
/// drained and the device has played its last buffer, then the device is reconfigured.
///
/// `use(_:)` moves playback to another device mid-track. When the device in use goes away and
/// another is chosen, the first is watched, and output goes back to it once it returns, unless
/// the other one is playing (ADR 0037).
public final class DeviceOutput: Output, @unchecked Sendable {
    public let events: AsyncStream<OutputEvent>
    /// The signal path each time the audible track, the gain or the device's state changes,
    /// from the device's first reported state on. Ends on `close()`.
    public let signalPaths: AsyncStream<SignalPath>
    /// The UID of each device output went back to on its own. Ends on `close()`.
    public let returns: AsyncStream<String>
    private let continuation: AsyncStream<OutputEvent>.Continuation
    private let signalContinuation: AsyncStream<SignalPath>.Continuation
    private let returnContinuation: AsyncStream<String>.Continuation
    /// Guards `pending`, `published`, `isClosed` and `volumeOn`, and wakes the control thread.
    private let condition = NSCondition()
    private var pending: [Command] = []
    private var published: OutputPosition?
    private var isClosed = false
    private var volumeOn: Bool

    // Everything below belongs to the control thread.
    private var choice: DeviceChoice
    private var provider: any PCMDeviceProvider { choice.provider }
    /// The device that went away while in use before another was chosen, to go back to.
    private var returnTo: DeviceChoice?
    /// What the device last reported, which a track has to fit before it plays.
    private var knownFormats: DeviceFormats?
    private var device: (any PCMDevice)?
    private var stream: RenderStream?
    /// The tracks in the ring buffer, oldest first. The first is the one playing.
    private var segments: [Segment] = [] {
        didSet { signalDirty = true }
    }
    /// The track being decoded into the ring buffer.
    private var feeding: Track?
    /// Opened as soon as the engine names it, so a slow NAS open happens while the current track
    /// still has seconds queued.
    private var next: Track?
    /// A next track that needs another format, waiting for the ring buffer to drain.
    private var pendingSwitch: Track?
    private var playing = false
    /// Whether the device is calling the IO proc.
    private var running = false
    /// When the ring buffer was found empty with nothing left to decode.
    private var drainedAt: Double?
    /// The device went away while in use, so its return is worth reporting.
    private var deviceMissing = false
    /// Where playback would resume after a device step failed while the device still read as
    /// connected. If the device then turns out to be gone, that's reported as a loss.
    private var failedResume: (item: OutputItem.ID?, seconds: Double)?
    /// How long a failed step waits for the device to read as gone before calling the failure
    /// the device's own: the HAL can report the removal a moment after the call fails.
    static let deviceSettleSeconds = 0.25
    private var gain: Double
    /// Nil until the provider first reports it.
    private var deviceState: DeviceState?
    private var publishedSignal: SignalPath?
    /// Set by whatever a signal path is built from, so a pass that changed none of it skips it.
    private var signalDirty = false
    /// Paths built, for tests. Guarded by `condition`.
    private var signalBuilds = 0
    /// Streams whose IO proc may still be called because stopping it failed. They are never freed.
    private var retired: [RenderStream] = []

    public init(_ choice: DeviceChoice) throws {
        self.choice = choice
        volumeOn = choice.digitalVolume
        gain = choice.gain
        knownFormats = choice.formats
        (events, continuation) = AsyncStream.makeStream(of: OutputEvent.self)
        (signalPaths, signalContinuation) = AsyncStream.makeStream(of: SignalPath.self)
        (returns, returnContinuation) = AsyncStream.makeStream(of: String.self)
        try watch(choice.provider)
        let thread = Thread { [self] in run() }
        thread.name = "DeviceOutput"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    public func load(_ item: OutputItem, startSeconds: Double, playing: Bool) {
        post(.load(item, startSeconds: startSeconds, playing: playing))
    }
    public func setNext(_ item: OutputItem?) { post(.setNext(item)) }
    public func play() { post(.play) }
    public func pause() { post(.pause) }
    public func stop() { post(.stop) }
    public func seek(toSeconds seconds: Double) { post(.seek(seconds)) }
    public func setVolume(_ gain: Double) { post(.volume(gain)) }
    public var hasVolume: Bool { condition.withLock { volumeOn } }
    /// Plays on `choice` from now on: the track playing carries on there from where it is. For the
    /// device in use, it only applies the new settings.
    public func use(_ choice: DeviceChoice) { post(.use(choice)) }
    public func position() -> OutputPosition? { condition.withLock { published } }
    var signalPathBuilds: Int { condition.withLock { signalBuilds } }

    public func close() {
        let done = DispatchSemaphore(value: 0)
        guard post(.close(done)) else { return }
        done.wait()
    }

    private enum Command {
        case load(OutputItem, startSeconds: Double, playing: Bool)
        case setNext(OutputItem?)
        case play, pause, stop
        case seek(Double)
        case volume(Double)
        case devicesChanged
        case deviceState(DeviceState, from: ObjectIdentifier)
        case use(DeviceChoice)
        case close(DispatchSemaphore)
    }

    /// Returns false once the output is closed.
    @discardableResult
    private func post(_ command: Command) -> Bool {
        condition.withLock {
            guard !isClosed else { return false }
            if case .close = command { isClosed = true }
            pending.append(command)
            condition.signal()
            return true
        }
    }

    private func run() {
        while true {
            condition.lock()
            if pending.isEmpty {
                if let interval = tickSeconds {
                    _ = condition.wait(until: Date(timeIntervalSinceNow: interval))
                } else {
                    condition.wait()
                }
            }
            let batch = pending
            pending = []
            condition.unlock()

            for command in batch {
                if case .close(let done) = command {
                    unload()
                    closeDevice()
                    provider.stopWatching()
                    returnTo?.provider.stopWatching()
                    publishPosition()
                    continuation.finish()
                    signalContinuation.finish()
                    returnContinuation.finish()
                    done.signal()
                    return
                }
                perform(command)
            }
            service()
            publishSignal()
        }
    }

    private var tickSeconds: Double? {
        guard let stream else { return nil }
        return controlTickSeconds(running: running, fillDue: feeding != nil && stream.isHalfEmpty)
    }

    private func perform(_ command: Command) {
        switch command {
        case .load(let item, let startSeconds, let playing):
            loadTrack(item, startSeconds: startSeconds, playing: playing)
        case .setNext(let item): replaceNext(item)
        case .play:
            playing = true
            startIfReady()
        case .pause:
            playing = false
            stopIO()
        case .stop:
            unload()
            closeDevice()
        case .seek(let seconds): seekTrack(toSeconds: seconds)
        case .volume(let gain):
            self.gain = gain
            signalDirty = true
            if let stream { HALRenderSetGain(stream.render, Float(gain)) }
        case .devicesChanged:
            checkDevice()
            checkReturn()
        case .deviceState(let state, let from):
            // One queued by a device that was in use before a switch.
            guard from == ObjectIdentifier(provider) else { return }
            deviceState = state
            if case .connected(let signal) = state { knownFormats = signal.formats }
            signalDirty = true
        case .use(let choice): use(choice, remembering: true)
        case .close: preconditionFailure("close is handled by the run loop")
        }
    }

    // MARK: Loading and seeking

    /// `announcing` false is for a track already playing, which a device switch reloads.
    private func loadTrack(
        _ item: OutputItem, startSeconds: Double, playing: Bool, announcing: Bool = true
    ) {
        unload()
        self.playing = playing
        let started = uptime()
        let track: Track
        do {
            track = try Track(item)
            try refuseUntakeable(track)
        } catch {
            cannotPlay(item, error)
            return
        }
        guard openDevice(for: item, at: startSeconds) else { return }
        let frame = track.frame(atSeconds: startSeconds)

        if let stream, stream.fits(track) {
            do {
                try restart(stream, with: track, atFrame: frame)
            } catch {
                cannotPlay(item, error)
                return
            }
            if playing { startIfReady() } else { stopIO() }
        } else {
            let from = stream?.format.summary
            stopIO(resuming: (item.id, startSeconds))
            stream = nil
            // Stopping can fail the device, which has been reported.
            guard device != nil else { return }
            let stream: RenderStream
            do {
                stream = try configure(for: track)
                try feed(track, into: stream, atFrame: frame)
            } catch {
                if deviceIsGone(after: error, resuming: item.id, at: startSeconds) { return }
                cannotPlay(item, error)
                return
            }
            fill(stream, upTo: stream.prefillBytes)
            startIfReady()
            // Starting can lose the device, which has been reported.
            guard device != nil else { return }
            emit(
                .formatChanged(
                    item.id,
                    FormatChange(
                        from: from, to: stream.format.summary, switchSeconds: uptime() - started)))
        }
        if announcing, let stream { emit(.trackStarted(item.id, stream.info(for: track))) }
    }

    /// Throws for a track that no rate or format the device reported carries unchanged, before
    /// the device is touched for it.
    private func refuseUntakeable(_ track: Track) throws {
        guard let knownFormats,
            !knownFormats.takes(sampleRateHz: track.sampleRateHz, channels: track.channels)
        else { return }
        throw DeviceOutputError.deviceCannotTake(
            device: provider.deviceName, sampleRateHz: track.sampleRateHz,
            channels: track.channels, knownFormats)
    }

    /// Reports a track that can't play at all, and releases the device since nothing else is
    /// loaded.
    private func cannotPlay(_ item: OutputItem, _ error: any Error) {
        emit(.trackFailed(item.id, error))
        unload()
        closeDevice()
        emit(.finished(item.id))
    }

    /// Opens the device unless a session already holds it. False when it isn't connected or
    /// failed, which has been reported.
    private func openDevice(for item: OutputItem, at seconds: Double) -> Bool {
        if device != nil { return true }
        do {
            guard let opened = try provider.open() else {
                deviceMissing = true
                emit(.deviceLost(item.id, positionSeconds: seconds))
                return false
            }
            device = opened
            deviceMissing = false
            failedResume = nil
            return true
        } catch {
            emit(.failed(item.id, error))
            return false
        }
    }

    private func configure(for track: Track) throws -> RenderStream {
        guard let device else { preconditionFailure("configure needs an open device") }
        let format = try device.configure(
            sampleRateHz: track.sampleRateHz, channels: track.channels)
        let stream = try RenderStream(format: format, withGain: choice.digitalVolume)
        if choice.digitalVolume { HALRenderSetGain(stream.render, Float(gain)) }
        self.stream = stream
        return stream
    }

    /// Starts decoding `track` into the ring buffer after whatever is there.
    private func feed(_ track: Track, into stream: RenderStream, atFrame frame: Int64) throws {
        try track.decoder.setOutputFormat(stream.decoderFormat)
        if frame > 0 { try track.decoder.seek(toFrame: frame) }
        feeding = track
        stream.dropChunk()
        segments.append(
            Segment(
                item: track.item, startByte: stream.produced, startFrame: frame,
                durationSeconds: track.durationSeconds, signal: track.signal(into: stream)))
        HALRenderSetDraining(stream.render, false)
        drainedAt = nil
    }

    /// Replaces everything queued with `track` from `frame`, without stopping the device: the IO
    /// proc discards what was written so far at the start of its next cycle.
    private func restart(_ stream: RenderStream, with track: Track, atFrame frame: Int64) throws {
        HALRenderDiscard(stream.render, 0, stream.produced)
        segments = []
        pendingSwitch = nil
        try feed(track, into: stream, atFrame: frame)
        fill(stream, upTo: stream.prefillBytes)
    }

    private func seekTrack(toSeconds seconds: Double) {
        guard let stream else { return }
        seekTrack(toFrame: Int64(seconds * stream.sampleRateHz))
    }

    private func seekTrack(toFrame frame: Int64) {
        guard let stream, let current = segments.first else { return }
        do {
            // Whatever was queued after the current track goes back to being the next track.
            if let committed = try committedNext() { next = committed }
            let track = try reusableTrack(for: current.item)
            try restart(stream, with: track, atFrame: track.clamped(frame))
        } catch {
            cannotPlay(current.item, error)
        }
    }

    /// The next track if it is already queued in the ring buffer or waiting for a format switch,
    /// rewound to its start.
    private func committedNext() throws -> Track? {
        if let pendingSwitch { return pendingSwitch }
        guard segments.count > 1 else { return nil }
        return try reusableTrack(for: segments[1].item)
    }

    /// The track being decoded, rewound, when it is `item`; otherwise `item` opened again.
    private func reusableTrack(for item: OutputItem) throws -> Track {
        guard let feeding, feeding.item.id == item.id else { return try Track(item) }
        try feeding.decoder.seek(toFrame: 0)
        return feeding
    }

    private func replaceNext(_ item: OutputItem?) {
        guard let stream, !segments.isEmpty else { return }
        // A boundary the IO proc has already played belongs to the track playing now, so announce
        // it rather than cut that track off.
        announceBoundaries(stream)
        if segments.count > 1 {
            // The old next track is already queued after the current one. The IO proc plays the
            // current track to its last byte, then skips the old next, so nothing is lost and the
            // replacement follows without a gap. Should the IO proc cross the boundary in the
            // microseconds before the discard lands, it cuts the old next track off a few
            // milliseconds in.
            HALRenderDiscard(stream.render, segments[1].startByte, stream.produced)
            segments.removeSubrange(1...)
            feeding = nil
            stream.dropChunk()
        }
        pendingSwitch = nil
        next = nil
        if let item {
            do {
                let track = try Track(item)
                try refuseUntakeable(track)
                next = track
            } catch {
                emit(.trackFailed(item.id, error))
            }
        }
        if feeding == nil { advanceFeed(stream) }
    }

    // MARK: Decoding and boundaries

    /// Decodes until the ring buffer is full, `limit` bytes are written, or nothing is left.
    private func fill(_ stream: RenderStream, upTo limit: Int = .max) {
        var written = 0
        while let track = feeding, written < limit {
            if stream.chunkIsEmpty {
                let frames: UInt32
                do {
                    frames = try track.decoder.read(
                        into: stream.chunk, frames: UInt32(RenderStream.chunkFrames))
                } catch {
                    // A truncated file, or a NAS that went away: end the track where its audio
                    // stops and carry on with the next.
                    emit(.trackFailed(track.item.id, error))
                    frames = 0
                }
                if frames == 0 {
                    if let cutShort = track.endedEarly {
                        emit(.trackFailed(track.item.id, cutShort))
                    }
                    advanceFeed(stream)
                    continue
                }
                stream.chunkDecoded(frames: Int(frames))
            }
            let count = stream.writeChunk()
            written += count
            if count == 0 { return }
        }
    }

    /// The track being decoded has ended: queue the next one behind it if it has the same format.
    private func advanceFeed(_ stream: RenderStream) {
        feeding = nil
        guard let next else {
            HALRenderSetDraining(stream.render, true)
            return
        }
        self.next = nil
        guard stream.fits(next) else {
            pendingSwitch = predecoded(next, after: stream)
            HALRenderSetDraining(stream.render, true)
            return
        }
        do {
            try feed(next, into: stream, atFrame: 0)
        } catch {
            emit(.trackFailed(next.item.id, error))
            HALRenderSetDraining(stream.render, true)
        }
    }

    /// `track` with its first half second decoded, while the current track still has seconds to
    /// drain, into the format the device will take after the switch: the same layout at the new
    /// rate. The switch then only has to reconfigure the device and copy it in. A track whose
    /// channel count differs can't be predicted, and one that fails here is decoded again at the
    /// switch, which reports the failure.
    private func predecoded(_ track: Track, after stream: RenderStream) -> Track {
        // Audio from an earlier drain is stale once the decoder has moved, so it never survives.
        var track = track
        track.predecoded = nil
        guard track.channels == stream.format.stream.mChannelsPerFrame else { return track }
        var format = stream.decoderFormat
        format.mSampleRate = track.sampleRateHz
        let frames = Int(track.sampleRateHz * RenderStream.prefillSeconds)
        var audio = Data(count: frames * Int(format.mBytesPerFrame))
        do {
            try track.decoder.seek(toFrame: 0)
            try track.decoder.setOutputFormat(format)
            var decoded = 0
            try audio.withUnsafeMutableBytes { bytes in
                while decoded < frames {
                    let read = try track.decoder.read(
                        into: bytes.baseAddress! + decoded * Int(format.mBytesPerFrame),
                        frames: UInt32(frames - decoded))
                    if read == 0 { break }
                    decoded += Int(read)
                }
            }
            audio.count = decoded * Int(format.mBytesPerFrame)
        } catch {
            logger.info("decoding ahead of a switch failed, retrying at the switch: \(error)")
            return track
        }
        var ahead = track
        ahead.predecoded = Predecoded(format: format, audio: audio)
        return ahead
    }

    private func service() {
        guard let stream else {
            publishPosition()
            return
        }
        if stream.isHalfEmpty { fill(stream) }
        announceBoundaries(stream)
        let consumed = HALRenderConsumedBytes(stream.render)
        if let frames = stream.newUnderrunFrames() { emit(.underrun(frames: frames)) }
        if running, feeding == nil, consumed >= stream.produced {
            drained(stream)
        } else {
            drainedAt = nil
        }
        publishPosition()
    }

    /// Ends the tracks whose last byte the IO proc has taken and starts the ones after them.
    private func announceBoundaries(_ stream: RenderStream) {
        let consumed = HALRenderConsumedBytes(stream.render)
        while segments.count > 1, consumed >= segments[1].startByte {
            let ended = segments.removeFirst()
            emit(.trackEnded(ended.item.id))
            emit(.trackStarted(segments[0].item.id, segments[0].info(stream)))
        }
    }

    /// The IO proc has taken everything. Once the device has had time to play it, end the track
    /// and either switch format for the next one or finish.
    private func drained(_ stream: RenderStream) {
        let now = uptime()
        guard let since = drainedAt else {
            drainedAt = now
            return
        }
        guard now - since >= stream.format.latencySeconds else { return }
        drainedAt = nil
        // The old track's last sample has now played: the switch is timed from here.
        let playedOut = now
        let last = segments.first?.item
        if let last { emit(.trackEnded(last.id)) }
        guard let track = pendingSwitch else {
            unload()
            closeDevice()
            if let last { emit(.finished(last.id)) }
            return
        }
        pendingSwitch = nil
        segments = []
        let from = stream.format.summary
        let clock = StepClock()
        clock.time("stop") { stopIO(resuming: (track.item.id, 0)) }
        self.stream = nil
        guard device != nil else { return }
        let next: RenderStream
        var ahead: Data?
        do {
            next = try configure(for: track)
            clock.add(next.format.steps)
            if let predecoded = track.predecoded,
                StoredFormat(predecoded.format) == StoredFormat(next.decoderFormat)
            {
                // The decoder is already past what was decoded ahead, in the right format.
                feeding = track
                next.dropChunk()
                segments.append(
                    Segment(
                        item: track.item, startByte: 0, startFrame: 0,
                        durationSeconds: track.durationSeconds, signal: track.signal(into: next)))
                ahead = predecoded.audio
            } else {
                try track.decoder.seek(toFrame: 0)
                try clock.time("open") { try feed(track, into: next, atFrame: 0) }
            }
        } catch {
            if deviceIsGone(after: error, resuming: track.item.id, at: 0) { return }
            emit(.trackFailed(track.item.id, error))
            unload()
            closeDevice()
            if let last { emit(.finished(last.id)) }
            return
        }
        if let ahead {
            clock.time("write") { next.write(ahead) }
        } else {
            clock.time("prefill") { fill(next, upTo: next.prefillBytes) }
        }
        clock.time("start") { startIfReady() }
        guard device != nil else { return }
        let switchSeconds = uptime() - playedOut
        // Whatever no step timed, such as allocating the ring buffer, so the steps add up.
        let other = switchSeconds - clock.steps.reduce(0) { $0 + $1.seconds }
        emit(
            .formatChanged(
                track.item.id,
                FormatChange(
                    from: from, to: next.format.summary, switchSeconds: switchSeconds,
                    steps: clock.steps + [SwitchStep(name: "other", seconds: max(other, 0))])))
        emit(.trackStarted(track.item.id, next.info(for: track)))
    }

    // MARK: The device

    private func startIfReady() {
        guard playing, !running, let device, let stream else { return }
        do {
            try device.start(stream.render)
            running = true
        } catch {
            if deviceIsGone(after: error, resuming: segments.first?.item.id, at: position()) {
                return
            }
            fail(error)
        }
    }

    /// Stops the IO proc. If the device is gone, playback resumes at `resume`, by default the
    /// track playing and where it is.
    private func stopIO(resuming resume: (item: OutputItem.ID?, seconds: Double)? = nil) {
        guard running, let device, let stream else { return }
        let resume = resume ?? (segments.first?.item.id, position())
        running = false
        do {
            try device.stop()
        } catch {
            retired.append(stream)
            if deviceIsGone(after: error, resuming: resume.item, at: resume.seconds) { return }
            fail(error)
        }
    }

    /// A device unplugged mid-switch fails the step it's in, before or after the HAL says it's
    /// gone, so a failed step while the device is gone, or goes within `deviceSettleSeconds`,
    /// is a lost device, not a failed track or output. True when it was, after reporting it.
    private func deviceIsGone(
        after error: any Error, resuming item: OutputItem.ID?, at seconds: Double
    ) -> Bool {
        let deadline = uptime() + Self.deviceSettleSeconds
        while provider.isConnected() {
            guard uptime() < deadline else {
                failedResume = (item, seconds)
                return false
            }
            usleep(10_000)
        }
        logger.error("\(self.provider.deviceName) went away: \(error)")
        lose(item, at: seconds)
        return true
    }

    /// The device itself failed: drop everything and report it.
    private func fail(_ error: any Error) {
        let item = segments.first?.item.id
        unload()
        closeDevice()
        emit(.failed(item, error))
    }

    private func unload() {
        segments = []
        feeding = nil
        next = nil
        pendingSwitch = nil
        drainedAt = nil
    }

    private func closeDevice() {
        guard let device else {
            stream = nil
            return
        }
        self.device = nil
        running = false
        do {
            try device.close()
        } catch {
            if let stream { retired.append(stream) }
            emit(.failed(nil, error))
        }
        stream = nil
    }

    private func checkDevice() {
        if device != nil {
            guard !provider.isConnected() else { return }
            logger.error("\(self.provider.deviceName) went away")
            lose(segments.first?.item.id, at: position())
        } else if let resume = failedResume, !provider.isConnected() {
            // A step failed while the device still read as connected, and now it's gone.
            failedResume = nil
            deviceMissing = true
            logger.error("\(self.provider.deviceName) went away after a failed step")
            emit(.deviceLost(resume.item, positionSeconds: resume.seconds))
        } else if deviceMissing, provider.isConnected() {
            deviceMissing = false
            provider.deviceReturned()
            emit(.deviceReturned)
        }
    }

    /// Goes back to the device that went away, now that it's here, unless this output is playing
    /// on the one chosen since.
    private func checkReturn() {
        guard let returnTo, returnTo.provider.isConnected(), !(playing && !segments.isEmpty)
        else { return }
        let uid = returnTo.provider.deviceUID
        logger.notice("\(returnTo.provider.deviceName) is back, so output returns to it")
        returnTo.provider.deviceReturned()
        use(returnTo, remembering: false)
        returnContinuation.yield(uid)
    }

    /// Moves to `next`'s device and settings, reloading the track playing at the same place and
    /// handing it the same next track. `remembering` sets the device in use as the one to return
    /// to when it has gone away and the user chose another.
    private func use(_ next: DeviceChoice, remembering: Bool) {
        let previous = choice
        let previousReturn = returnTo
        let wasMissing = deviceMissing
        let resume = segments.first.map { (item: $0.item, seconds: position() as Double) }
        let following =
            pendingSwitch?.item ?? (segments.count > 1 ? segments[1].item : nil) ?? self.next?.item
        let wasPlaying = playing
        unload()
        closeDevice()

        let uid = next.provider.deviceUID
        if uid == returnTo?.provider.deviceUID {
            returnTo = nil
        } else if remembering, wasMissing, uid != previous.provider.deviceUID {
            returnTo = previous
        }
        choice = next
        let before = [previous.provider] + (previousReturn.map { [$0.provider] } ?? [])
        let after = [next.provider] + (returnTo.map { [$0.provider] } ?? [])
        for provider in before where !after.contains(where: { $0 === provider }) {
            provider.stopWatching()
        }
        for provider in after where !before.contains(where: { $0 === provider }) {
            do {
                try watch(provider)
            } catch {
                emit(.failed(nil, error))
            }
        }
        condition.withLock { volumeOn = next.digitalVolume }
        gain = next.gain
        knownFormats = next.formats
        if next.provider !== previous.provider { deviceState = nil }
        signalDirty = true
        deviceMissing = false
        failedResume = nil
        if wasMissing, next.provider.isConnected() { emit(.deviceReturned) }
        guard let resume else { return }
        loadTrack(
            resume.item, startSeconds: resume.seconds, playing: wasPlaying, announcing: false)
        if let following { replaceNext(following) }
    }

    /// States from a provider no longer in use are dropped by the identity they carry.
    private func watch(_ provider: any PCMDeviceProvider) throws {
        let id = ObjectIdentifier(provider)
        try provider.watch(
            { [weak self] in self?.post(.devicesChanged) },
            state: { [weak self] in self?.post(.deviceState($0, from: id)) })
    }

    /// The device is gone: drop everything without restoring it, and report where to resume.
    private func lose(_ item: OutputItem.ID?, at seconds: Double) {
        if let device, !device.abandon(), let stream, !retired.contains(where: { $0 === stream }) {
            retired.append(stream)
        }
        device = nil
        running = false
        stream = nil
        unload()
        deviceMissing = true
        emit(.deviceLost(item, positionSeconds: seconds))
    }

    // MARK: Position and events

    /// Where the track playing is, or 0 before anything plays.
    private func position() -> Double { positionSeconds() ?? 0 }

    private func positionSeconds() -> Double? {
        guard let stream, let segment = segments.first else { return nil }
        let consumed = HALRenderConsumedBytes(stream.render)
        let played =
            consumed > segment.startByte
            ? Int64((consumed - segment.startByte) / UInt64(stream.bytesPerFrame)) : 0
        return Double(segment.startFrame + played) / stream.sampleRateHz
    }

    private func publishPosition() {
        let position = segments.first.flatMap { segment in
            positionSeconds().map { OutputPosition(item: segment.item.id, seconds: $0) }
        }
        condition.withLock { published = position }
    }

    private func emit(_ event: OutputEvent) { continuation.yield(event) }

    /// Runs after every pass of the control thread, and builds a path only when its sources moved.
    private func publishSignal() {
        guard signalDirty, let deviceState else { return }
        signalDirty = false
        condition.withLock { signalBuilds += 1 }
        let path = SignalPath(
            track: segments.first?.signal,
            sink: .device(
                DeviceSink(
                    name: provider.deviceName, uid: provider.deviceUID, state: deviceState,
                    gain: choice.digitalVolume ? gain : 1)))
        guard path != publishedSignal else { return }
        publishedSignal = path
        signalContinuation.yield(path)
    }
}

private func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

/// How often the control thread refills and looks for track boundaries, or nil to sleep until a
/// command. The ring buffer holds seconds, so this only sets how late an event can be. Stopped,
/// nothing moves but decoding ahead, so once that's done the thread doesn't wake at all.
func controlTickSeconds(running: Bool, fillDue: Bool) -> Double? {
    if running { return 0.01 }
    return fillDue ? 0.05 : nil
}

/// A file opened for decoding.
private struct Track {
    let item: OutputItem
    let decoder: FileDecoder
    /// The start of the track, decoded while the track before it drained.
    var predecoded: Predecoded?

    /// The length decoding should reach, in frames: the decoder's, except for an MP3, where
    /// AudioToolbox estimates it from the file size, so it's the length a Xing/Info or VBRI
    /// header states, or nil when there's none and the length can't be checked.
    let checkedLengthFrames: Int64?

    init(_ item: OutputItem) throws {
        self.item = item
        decoder = try FileDecoder(url: item.url)
        if decoder.fileFormat.mFormatID == kAudioFormatMPEGLayer3 {
            do {
                checkedLengthFrames = try mp3StatedLengthFrames(at: item.url).map(Int64.init)
            } catch {
                // AudioToolbox opened it, so this only means its length can't be checked.
                logger.info("can't read the length \(item.url.path) states: \(error)")
                checkedLengthFrames = nil
            }
        } else {
            checkedLengthFrames = decoder.lengthFrames
        }
    }

    var sampleRateHz: Double { decoder.fileFormat.mSampleRate }
    var channels: UInt32 { decoder.fileFormat.mChannelsPerFrame }
    var durationSeconds: Double { Double(decoder.lengthFrames) / sampleRateHz }

    func frame(atSeconds seconds: Double) -> Int64 { clamped(Int64(seconds * sampleRateHz)) }

    func clamped(_ frame: Int64) -> Int64 { min(max(0, frame), decoder.lengthFrames) }

    func signal(into stream: RenderStream) -> TrackSignal {
        TrackSignal(
            file: SignalFormat(decoder.fileFormat), decoded: SignalFormat(stream.decoderFormat))
    }

    /// Why decoding stopped short, once it has: nil unless it's more than
    /// `endedEarlySeconds` before the stated length, which leaves room for encoders' rounding.
    /// An MP3 that doesn't state its length isn't checked.
    var endedEarly: DeviceOutputError? {
        guard let length = checkedLengthFrames else { return nil }
        let missing = Double(length - decoder.nextFrame) / sampleRateHz
        guard missing > Self.endedEarlySeconds else { return nil }
        return .endedEarly(
            atSeconds: Double(decoder.nextFrame) / sampleRateHz,
            ofSeconds: Double(length) / sampleRateHz)
    }

    static let endedEarlySeconds = 0.5
}

private struct Predecoded {
    let format: AudioStreamBasicDescription
    let audio: Data
}

/// A track's place in the ring buffer.
private struct Segment {
    let item: OutputItem
    /// The count of bytes written when its first byte went in.
    let startByte: UInt64
    /// The frame of the file it starts at, after a seek.
    let startFrame: Int64
    let durationSeconds: Double
    let signal: TrackSignal

    func info(_ stream: RenderStream) -> TrackInfo {
        TrackInfo(durationSeconds: durationSeconds, outputFormat: stream.format.summary)
    }
}

/// The ring buffer and render state for one device format, and the decode chunk that feeds them.
private final class RenderStream {
    static let chunkFrames = 32768
    /// Eight seconds of audio, refilled once half empty. Half of it is margin: for a NAS read
    /// that stalls, and for opening the next track on the same thread while this drains. The
    /// other half sets how long each refill runs; one twice as long let the scheduler give
    /// decoding a fast core for more of it, which cut playback CPU by a quarter (ADR 0029). A
    /// seek doesn't wait for it to empty (`HALRenderDiscard`), so its size costs memory, not
    /// responsiveness: 2.8 MB at 44.1 kHz stereo 32-bit, 12 MB at 192 kHz, 49 MB at 768 kHz, which
    /// the ring rounds up to a power of two (4, 16 and 64 MB).
    static let bufferSeconds = 8.0
    /// Queued before the device starts, so a track change doesn't wait for the whole buffer.
    static let prefillSeconds = 0.5

    let ring: OpaquePointer
    let render: OpaquePointer
    let format: DeviceFormat
    let bytesPerFrame: Int
    let chunk: UnsafeMutableRawPointer
    /// Bytes written to the ring buffer since it was created.
    private(set) var produced: UInt64 = 0
    private var chunkBytes = 0
    private var chunkOffset = 0
    private var reportedUnderrunBytes: UInt64 = 0

    /// `withGain` needs a sample layout the IO proc can scale.
    init(format: DeviceFormat, withGain: Bool) throws {
        let stream = format.stream
        let samples: HALRenderSampleKind
        if let kind = renderSampleKind(stream) {
            samples = kind
        } else if withGain {
            throw DeviceOutputError.noVolumeForFormat(format.summary)
        } else {
            // The gain stays at unity, so the IO proc never looks at the layout.
            samples = HALRenderSamplesInt32
        }
        self.format = format
        bytesPerFrame = Int(stream.mBytesPerFrame)
        guard
            let ring = RingBufferCreate(
                Int(stream.mSampleRate * Self.bufferSeconds) * bytesPerFrame)
        else { throw DeviceOutputError.outOfMemory }
        guard let render = HALRenderCreate(ring, samples) else {
            RingBufferDestroy(ring)
            throw DeviceOutputError.outOfMemory
        }
        self.ring = ring
        self.render = render
        chunk = .allocate(byteCount: Self.chunkFrames * bytesPerFrame, alignment: 16)
    }

    /// Only once the IO proc has stopped reading.
    deinit {
        HALRenderDestroy(render)
        RingBufferDestroy(ring)
        chunk.deallocate()
    }

    var sampleRateHz: Double { format.stream.mSampleRate }
    var prefillBytes: Int { Int(sampleRateHz * Self.prefillSeconds) * bytesPerFrame }

    /// The format to decode into. The converter rejects the non-mixable flag, which describes the
    /// hardware, not the samples.
    var decoderFormat: AudioStreamBasicDescription {
        var format = format.stream
        format.mFormatFlags &= ~kAudioFormatFlagIsNonMixable
        return format
    }

    func fits(_ track: Track) -> Bool {
        track.sampleRateHz == sampleRateHz && track.channels == format.stream.mChannelsPerFrame
    }

    func info(for track: Track) -> TrackInfo {
        TrackInfo(durationSeconds: track.durationSeconds, outputFormat: format.summary)
    }

    var chunkIsEmpty: Bool { chunkOffset == chunkBytes }

    /// Refilling only from half empty decodes in bursts of two seconds instead of a few
    /// milliseconds every tick. The CPU then runs the work at full clock and goes back to sleep,
    /// which measured a third of the CPU time of topping up every tick.
    var isHalfEmpty: Bool { RingBufferReadable(ring) <= RingBufferCapacity(ring) / 2 }

    func dropChunk() {
        chunkBytes = 0
        chunkOffset = 0
    }

    func chunkDecoded(frames: Int) {
        chunkBytes = frames * bytesPerFrame
        chunkOffset = 0
    }

    /// Writes as many whole frames of the chunk as fit and returns how many bytes that was. Whole
    /// frames keep every count the IO proc and the boundaries use on a frame edge.
    func writeChunk() -> Int {
        let space = RingBufferCapacity(ring) - RingBufferReadable(ring)
        let count = RingBufferWrite(
            ring, chunk + chunkOffset, min(chunkBytes - chunkOffset, space - space % bytesPerFrame))
        chunkOffset += count
        produced += UInt64(count)
        return count
    }

    /// Queues audio decoded elsewhere. The ring buffer is empty and holds seconds, so it all fits.
    func write(_ audio: Data) {
        guard !audio.isEmpty else { return }
        let count = audio.withUnsafeBytes { RingBufferWrite(ring, $0.baseAddress!, $0.count) }
        precondition(count == audio.count, "decoded-ahead audio didn't fit an empty ring buffer")
        produced += UInt64(count)
    }

    /// Frames of underrun since the last call, or nil when there were none.
    func newUnderrunFrames() -> Int? {
        let bytes = HALRenderUnderrunBytes(render)
        guard bytes > reportedUnderrunBytes else { return nil }
        defer { reportedUnderrunBytes = bytes }
        return Int(bytes - reportedUnderrunBytes) / bytesPerFrame
    }
}
