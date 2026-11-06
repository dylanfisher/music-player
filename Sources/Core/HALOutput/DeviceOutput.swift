import CoreAudio
import DisplayText
import Foundation
import HALRender
import Log
import Metadata
import Playback
import RingBuffer

private let logger = moduleLogger()

enum DeviceOutputError: PlaybackFailure {
    case outOfMemory
    case noVolumeForFormat(String)
    /// The file's audio stopped well before the length its header gives, as a partial file's
    /// or one cut short while it played does.
    case endedEarly(atSeconds: Double, ofSeconds: Double)
    /// A DSD track the device can't carry as DoP unchanged.
    case cannotPlayDSD(
        device: String, deviceUID: String, dsdRateHz: Int, carrierRateHz: Double, DoPRefusal)
    /// The device format the DoP reader was handed can't hold DoP words unchanged.
    case noDoPLayout(SignalFormat)
    /// The device's format has fewer channels than the track but more than two, and only stereo
    /// and mono get a downmix.
    case noChannelMix(fromChannels: UInt32, toChannels: UInt32)

    var description: String {
        switch self {
        case .outOfMemory: "couldn't allocate the playback buffer"
        case .endedEarly(let at, let length):
            String(format: "the audio ends at %.1f s of %.1f s; the file is cut short", at, length)
        case .noVolumeForFormat(let format):
            "the digital volume can't scale samples in this device format: \(format)"
        case .cannotPlayDSD(let device, _, let dsd, let carrier, let refusal):
            "\(device) can't play \(sampleRateText(dsd)): "
                + {
                    switch refusal {
                    case .noRate: "it has no \(kilohertz(carrier)) kHz rate for DoP"
                    case .noFormat:
                        "it has no non-mixable \(dopWordBits)-bit integer format at"
                            + " \(kilohertz(carrier)) kHz for DoP"
                    case .noHogMode:
                        "DoP needs exclusive access, and hog mode is off for this device"
                    }
                }()
        case .noDoPLayout(let format):
            "DoP needs a \(dopWordBits)-bit integer device format; this one is \(format.formatID)"
                + " \(depthText(bits: format.bitsPerChannel ?? 0, isFloat: format.isFloat))"
        case .noChannelMix(let from, let to):
            "the device's format has \(to) channels for this \(from)-channel track, and only"
                + " stereo and mono get a downmix"
        }
    }

    var userMessage: String {
        switch self {
        case .outOfMemory: "the Mac is out of memory for playback"
        case .noVolumeForFormat:
            "the digital volume can't work in the device's format; turn it off to play"
        case .cannotPlayDSD(let device, _, let dsd, let carrier, .noFormat):
            "\(device) can't play \(sampleRateText(dsd)): none of its formats at"
                + " \(kilohertz(carrier)) kHz can carry DoP"
        // Without the rate, so every DSD track refused for it has one cause and one fix.
        case .cannotPlayDSD(_, _, _, _, .noHogMode):
            "DoP needs exclusive access, and hog mode is off for this device"
        case .noDoPLayout: "the device's format can't carry DSD as DoP"
        case .endedEarly, .cannotPlayDSD, .noChannelMix: description
        }
    }

    var fix: PlaybackFix? {
        guard case .cannotPlayDSD(_, let uid, _, _, .noHogMode) = self else { return nil }
        return .turnOnHogMode(deviceUID: uid)
    }
}

/// Why a device can't carry DSD as DoP. The macOS mixer and the system volume can rewrite the
/// words of a mixable format, so DoP needs a non-mixable one, which needs hog mode.
enum DoPRefusal: Sendable {
    case noRate, noFormat, noHogMode
}

/// Plays tracks bit-perfect on the device a `PCMDeviceProvider` finds, as an `Output`, or
/// converted to the device's best format when it can't take a track unchanged (ADR 0071).
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
    /// Guards `pending`, `published`, `seekTarget`, `isClosed` and `volumeOn`, and wakes the
    /// control thread.
    private let condition = NSCondition()
    /// Each command with the interval generation current when it was posted.
    private var pending: [(command: Command, generation: UInt64)] = []
    private var published: OutputPosition?
    /// The last seek posted, and how many posted seeks the control thread hasn't done.
    /// `position()` reports it until they're all done: `published` holds the time from before
    /// the seek until then, which a refill on a NAS can make last a while.
    private var seekTarget: (seconds: Double, unfinished: Int)?
    private var isClosed = false
    private var volumeOn: Bool

    // Everything below belongs to the control thread.
    private var choice: DeviceChoice
    private var provider: any PCMDeviceProvider { choice.provider }
    /// The device that went away while in use before another was chosen, to go back to.
    private var returnTo: DeviceChoice?
    /// Set when the device list changed or playback stopped, so the pass ends by checking whether
    /// to go back to `returnTo`.
    private var returnDue = false
    /// What the device last reported, which a DSD track has to fit before it plays.
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
    private let fileLatency: FileLatency?
    /// The play-to-first-sample interval: begun when a load or seek is posted, ended here once
    /// the device has taken a sample of the new audio, cancelled when none will follow.
    private let firstSound: PendingInterval
    /// The consumed-bytes count the IO proc must pass for the interval to end: the start of the
    /// audio the last load or seek queued. Nil until the control thread has processed it, so
    /// audio from before it can't end the interval.
    private var firstSoundTarget: (generation: UInt64, byte: UInt64)?
    /// The interval generation current when the command now running was posted, or when the
    /// pass began; a cancel reaches no later interval than this.
    private var passGeneration: UInt64 = 0

    /// `fileLatency` is for benchmarks: it makes PCM files read as from a NAS. `firstSound` is
    /// for tests.
    public init(
        _ choice: DeviceChoice, fileLatency: FileLatency? = nil,
        firstSound: PendingInterval = .firstSound
    ) throws {
        self.choice = choice
        self.fileLatency = fileLatency
        self.firstSound = firstSound
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
        let generation = playing ? firstSound.begin() : nil
        if !post(.load(item, startSeconds: startSeconds, playing: playing)), let generation {
            firstSound.cancel(upTo: generation)
        }
    }
    public func setNext(_ item: OutputItem?) { post(.setNext(item)) }
    /// `load` and `setNext` in one post, so the control thread has both before it first decodes.
    /// Two posts leave a gap in which it may decode a short first track to its end, and the next
    /// track then lands in a ring buffer that has nothing of it decoded.
    func load(_ item: OutputItem, next: OutputItem, startSeconds: Double, playing: Bool) {
        post(.load(item, startSeconds: startSeconds, playing: playing), .setNext(next))
    }
    public func play() { post(.play) }
    public func pause() { post(.pause) }
    public func stop() { post(.stop) }
    public func seek(toSeconds seconds: Double) {
        let generation = firstSound.begin()
        // Before the post, so the control thread can't finish the seek before it's counted.
        condition.withLock { seekTarget = (seconds, (seekTarget?.unfinished ?? 0) + 1) }
        if !post(.seek(seconds)) {
            firstSound.cancel(upTo: generation)
            finishSeek()
        }
    }
    public func setVolume(_ gain: Double) { post(.volume(gain)) }
    public var hasVolume: Bool { condition.withLock { volumeOn } }
    /// Plays on `choice` from now on: the track playing carries on there from where it is. For the
    /// device in use, it only applies the new settings.
    public func use(_ choice: DeviceChoice) { post(.use(choice)) }
    public func position() -> OutputPosition? {
        condition.withLock {
            guard var position = published else { return nil }
            if let seekTarget { position.seconds = seekTarget.seconds }
            return position
        }
    }
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
    private func post(_ commands: Command...) -> Bool {
        condition.withLock {
            guard !isClosed else { return false }
            for command in commands { if case .close = command { isClosed = true } }
            let generation = firstSound.generation
            pending.append(contentsOf: commands.map { ($0, generation) })
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

            for (command, generation) in batch {
                passGeneration = generation
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
            passGeneration = firstSound.generation
            service()
            if returnDue {
                returnDue = false
                checkReturn()
            }
            publishSignal()
        }
    }

    private var tickSeconds: Double? {
        guard let stream else { return nil }
        let fillDue = (feeding != nil || stream.hasTailToWrite) && stream.isHalfEmpty
        return controlTickSeconds(running: running, fillDue: fillDue)
    }

    private func perform(_ command: Command) {
        switch command {
        case .load(let item, let startSeconds, let playing):
            loadTrack(item, startSeconds: startSeconds, playing: playing)
            armFirstSound()
        case .setNext(let item): replaceNext(item)
        case .play:
            playing = true
            startIfReady()
        case .pause:
            playing = false
            cancelFirstSound()
            stopIO()
            returnDue = true
        case .stop:
            unload()
            closeDevice()
            returnDue = true
        case .seek(let seconds):
            seekTrack(toSeconds: seconds)
            armFirstSound()
            publishPosition()
            finishSeek()
        case .volume(let gain):
            self.gain = gain
            signalDirty = true
            // Kept for the next PCM track: DoP plays at unity whatever the volume.
            if let stream, !stream.isDoP { HALRenderSetGain(stream.render, Float(gain)) }
        case .devicesChanged:
            checkDevice()
            returnDue = true
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

    /// Waits for the sound of what the load or seek just processed queued, or cancels the
    /// interval when nothing plays.
    private func armFirstSound() {
        guard playing, stream != nil, let first = segments.first else {
            cancelFirstSound()
            return
        }
        // A newer play was begun since this command was posted: it arms its own.
        guard firstSound.generation == passGeneration else { return }
        firstSoundTarget = (passGeneration, first.startByte)
    }

    private func cancelFirstSound() {
        firstSoundTarget = nil
        firstSound.cancel(upTo: passGeneration)
    }

    /// `announcing` false is for a track already playing, which a device switch reloads.
    private func loadTrack(
        _ item: OutputItem, startSeconds: Double, playing: Bool, announcing: Bool = true
    ) {
        let reused = openTrack(for: item)
        unload()
        self.playing = playing
        let started = uptime()
        let track: Track
        do {
            track = try reused ?? Track(item, latency: fileLatency)
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
            let from = stream?.outputFormat
            stopIO(resuming: (item.id, startSeconds))
            stream = nil
            // Stopping can fail the device, which has been reported.
            guard device != nil else { return }
            let stream: RenderStream
            do {
                stream = try configure(for: track)
            } catch {
                if deviceIsGone(after: error, resuming: item.id, at: startSeconds) { return }
                // The track was checked against the device's formats, so this is the device's
                // failure: every track after it would fail the same way.
                fail(error, item: item.id)
                return
            }
            do {
                try feed(track, into: stream, atFrame: frame)
            } catch {
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
                        from: from, to: stream.outputFormat, switchSeconds: uptime() - started)))
        }
        if announcing, let stream { emit(.trackStarted(item.id, stream.info(for: track))) }
    }

    /// Throws for a DSD track the device can't carry as DoP, before the device is touched for
    /// it. A PCM track always plays, converted if need be; DSD isn't converted (ADR 0071).
    private func refuseUntakeable(_ track: Track) throws {
        if track.isDoP {
            let rate = track.sampleRateHz
            let refusal: DoPRefusal?
            if !provider.usesHogMode {
                refusal = .noHogMode
            } else if let knownFormats {
                let hasFormat = knownFormats.formats.contains {
                    $0.carries(sampleRateHz: rate, channels: track.channels)
                        && $0.bitsPerChannel >= dopWordBits && !$0.isMixable
                }
                if !knownFormats.sampleRatesHz.contains(where: { $0.contains(rate) }) {
                    refusal = .noRate
                } else {
                    refusal = hasFormat ? nil : .noFormat
                }
            } else {
                refusal = nil
            }
            if let refusal {
                throw DeviceOutputError.cannotPlayDSD(
                    device: provider.deviceName, deviceUID: provider.deviceUID,
                    dsdRateHz: Int(track.file.sampleRateHz),
                    carrierRateHz: rate, refusal)
            }
        }
    }

    /// Reports a track that can't play at all, and releases the device since nothing else is
    /// loaded.
    private func cannotPlay(_ item: OutputItem, _ error: any Error) {
        emit(.trackFailed(item.id, error))
        unload()
        closeDevice()
        emit(.finished(item.id))
        returnDue = true
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
            sampleRateHz: track.sampleRateHz, channels: track.channels,
            forDoP: track.isDoP, file: track.file)
        // DoP is never scaled, so its stream gets no gain at all.
        let withGain = choice.digitalVolume && !track.isDoP
        let stream = try RenderStream(format: format, for: track, withGain: withGain)
        if withGain { HALRenderSetGain(stream.render, Float(gain)) }
        self.stream = stream
        return stream
    }

    /// Starts decoding `track` into the ring buffer after whatever is there.
    private func feed(_ track: Track, into stream: RenderStream, atFrame frame: Int64) throws {
        try track.decoder.setOutputFormat(stream.decoderFormat)
        if frame > 0 { try track.decoder.seek(toFrame: frame) }
        let startByte = try stream.startTrack()
        feeding = track
        stream.clearTail()
        segments.append(
            Segment(
                track: track, startByte: startByte,
                startSeconds: Double(frame) / track.sampleRateHz,
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
        stream.dropChunk()
        try stream.converter?.reset()
        try feed(track, into: stream, atFrame: frame)
        fill(stream, upTo: stream.prefillBytes)
    }

    private func seekTrack(toSeconds seconds: Double) {
        guard let stream, let current = segments.first else { return }
        do {
            // Whatever was queued after the current track goes back to being the next track.
            if let committed = try committedNext() { next = committed }
            let track = try reusableTrack(for: current.item)
            try restart(stream, with: track, atFrame: track.frame(atSeconds: seconds))
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

    /// `item`'s track, rewound, when it's being decoded or still queued; otherwise `item`
    /// opened again.
    private func reusableTrack(for item: OutputItem) throws -> Track {
        let open = [feeding].compactMap { $0 } + segments.map(\.track)
        guard let track = open.first(where: { $0.item.id == item.id }) else {
            return try Track(item, latency: fileLatency)
        }
        try track.decoder.seek(toFrame: 0)
        return track
    }

    /// A track already open on `item`'s file, as Next's track is once the engine named it,
    /// rewound and given `item`; nil when there is none. Opening a file on a NAS costs round
    /// trips the open one has already paid.
    private func openTrack(for item: OutputItem) -> Track? {
        let open =
            [next, pendingSwitch, feeding].compactMap { $0 } + segments.map(\.track)
        guard var track = open.first(where: { $0.item.url == item.url }) else { return nil }
        do {
            try track.decoder.seek(toFrame: 0)
        } catch {
            logger.info("rewinding an open track failed, opening it again: \(error)")
            return nil
        }
        track.item = item
        track.predecoded = nil
        return track
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
            do {
                try stream.keep(upTo: segments[1].startByte)
            } catch {
                fail(error)
                return
            }
            segments.removeSubrange(1...)
            feeding = nil
        }
        pendingSwitch = nil
        next = nil
        // A DoP tail queued because no next track had been named yet: the IO proc skips what
        // it hasn't played of it, so the new next track follows the audio without a gap.
        if item != nil, let tailStart = stream.tailStart {
            let from = tailDiscardStart(
                tailStart: tailStart, consumed: HALRenderConsumedBytes(stream.render),
                pairBytes: UInt64(2 * stream.bytesPerFrame))
            HALRenderDiscard(stream.render, from, stream.produced)
            stream.clearTail()
            stream.dropChunk()
        }
        if let item {
            do {
                let track = try Track(item, latency: fileLatency)
                try refuseUntakeable(track)
                next = track
            } catch {
                emit(.trackFailed(item.id, error))
            }
        }
        if feeding == nil { advanceFeed(stream) }
    }

    // MARK: Decoding and boundaries

    /// Decodes until the ring buffer is full, `limit` bytes are written, or nothing is left. A
    /// refill with no limit also stops after any chunk once a command is waiting: a refill is up
    /// to 7.5 s of audio, which on hi-res FLAC from a NAS takes hundreds of milliseconds, and a
    /// seek that waited for it made scrubbing lag (ADR 0083). The next pass carries on.
    private func fill(_ stream: RenderStream, upTo limit: Int = .max) {
        var written = 0
        while written < limit {
            if stream.chunkIsEmpty {
                guard let track = feeding else {
                    guard stream.tailIsDue else { return }
                    do {
                        try stream.chunkTail()
                    } catch {
                        if let last = segments.last { emit(.trackFailed(last.item.id, error)) }
                        stream.dropTail()
                    }
                    continue
                }
                let frames: UInt32
                do {
                    frames = try stream.decode(track)
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
            if limit == .max, condition.withLock({ !pending.isEmpty }) { return }
        }
    }

    /// The track being decoded has ended: queue the next one behind it if it has the same format.
    private func advanceFeed(_ stream: RenderStream) {
        feeding = nil
        guard let next else {
            endFeed(stream)
            return
        }
        self.next = nil
        guard stream.fits(next) else {
            pendingSwitch = predecodes(next, after: stream) ? predecoded(next, after: stream) : next
            endFeed(stream)
            return
        }
        do {
            try feed(next, into: stream, atFrame: 0)
        } catch {
            emit(.trackFailed(next.item.id, error))
            endFeed(stream)
        }
    }

    /// Nothing more follows in this stream. DoP gets a tail of DoP silence, so the IO proc
    /// doesn't pad the drain with zeros, which a DAC takes as PCM and may click on; a converter
    /// gives up what it still holds of the last track.
    private func endFeed(_ stream: RenderStream) {
        stream.startTail()
        HALRenderSetDraining(stream.render, true)
    }

    /// Whether decoding `track`'s start ahead of a switch can pay off: not when this stream or the
    /// next converts, since the switch can't take audio decoded in the guessed format and would
    /// decode it again.
    private func predecodes(_ track: Track, after stream: RenderStream) -> Bool {
        guard !stream.format.isConverted else { return false }
        guard !track.isDoP, let knownFormats else { return true }
        return knownFormats.takes(sampleRateHz: track.sampleRateHz, channels: track.channels)
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
        // The IO proc has taken a sample of what the last load or seek queued; it can't end the
        // interval itself.
        if let target = firstSoundTarget, consumed > target.byte {
            firstSoundTarget = nil
            firstSound.end(generation: target.generation)
        }
        if let frames = stream.newUnderrunFrames() { emit(.underrun(frames: frames)) }
        if running, feeding == nil, !stream.hasTailToWrite, stream.chunkIsEmpty,
            consumed >= stream.audioEndByte
        {
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
            returnDue = true
            return
        }
        pendingSwitch = nil
        segments = []
        let from = stream.outputFormat
        let clock = StepClock()
        clock.time("stop") { stopIO(resuming: (track.item.id, 0)) }
        self.stream = nil
        guard device != nil else { return }
        let next: RenderStream
        var ahead: Data?
        do {
            next = try configure(for: track)
        } catch {
            if deviceIsGone(after: error, resuming: track.item.id, at: 0) { return }
            fail(error, item: track.item.id)
            return
        }
        clock.add(next.format.steps)
        do {
            // Audio decoded ahead goes straight in, so a stream that converts can't take it.
            if let predecoded = track.predecoded, next.converter == nil,
                StoredFormat(predecoded.format) == StoredFormat(next.decoderFormat)
            {
                // The decoder is already past what was decoded ahead, in the right format.
                feeding = track
                next.dropChunk()
                segments.append(
                    Segment(
                        track: track, startByte: 0, startSeconds: 0,
                        durationSeconds: track.durationSeconds, signal: track.signal(into: next)))
                ahead = predecoded.audio
            } else {
                try track.decoder.seek(toFrame: 0)
                try clock.time("open") { try feed(track, into: next, atFrame: 0) }
            }
        } catch {
            emit(.trackFailed(track.item.id, error))
            unload()
            closeDevice()
            if let last { emit(.finished(last.id)) }
            returnDue = true
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
                    from: from, to: next.outputFormat, switchSeconds: switchSeconds,
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

    /// The device itself failed: drop everything and report it for `item`, by default the track
    /// playing.
    private func fail(_ error: any Error, item: OutputItem.ID? = nil) {
        let item = item ?? segments.first?.item.id
        unload()
        closeDevice()
        emit(.failed(item, error))
    }

    private func unload() {
        firstSoundTarget = nil
        segments = []
        feeding = nil
        next = nil
        pendingSwitch = nil
        drainedAt = nil
    }

    private func closeDevice() {
        cancelFirstSound()
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
        // Watching again reports each device's state now, which a device watched only for its
        // return had its reports dropped.
        if next.provider !== previous.provider || returnTo?.provider !== previousReturn?.provider {
            previous.provider.stopWatching()
            previousReturn?.provider.stopWatching()
            for provider in [next.provider] + (returnTo.map { [$0.provider] } ?? []) {
                do {
                    try watch(provider)
                } catch {
                    emit(.failed(nil, error))
                }
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
        cancelFirstSound()
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
            ? (consumed - segment.startByte) / UInt64(stream.bytesPerFrame) : 0
        return segment.startSeconds + Double(played) / stream.sampleRateHz
    }

    private func publishPosition() {
        let position = segments.first.flatMap { segment in
            positionSeconds().map { OutputPosition(item: segment.item.id, seconds: $0) }
        }
        condition.withLock { published = position }
    }

    /// One posted seek is done, and `published` already says where it went.
    private func finishSeek() {
        condition.withLock {
            guard let target = seekTarget else { return }
            seekTarget = target.unfinished > 1 ? (target.seconds, target.unfinished - 1) : nil
        }
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
                    gain: choice.digitalVolume && stream?.isDoP != true ? gain : 1)))
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

/// After the last DoP track the drain waits out the device's latency once the IO proc has taken
/// the last byte of audio, notices on a 10 ms control tick, and then stops the device, which takes
/// a few milliseconds more; the IO proc keeps pulling all the while. A tail of DoP silence this
/// much longer than the latency covers that with room to spare, and the stop discards what's left
/// of it.
let dopTailSeconds = 0.1

/// Where to cut a DoP tail for a next track: its start, or once the IO proc is inside it, the
/// next pair of frames after where it is, so the track still starts on an even frame and the
/// markers keep their order. Should the IO proc pass that point before the discard lands, it
/// skips from where its next cycle starts instead.
func tailDiscardStart(tailStart: UInt64, consumed: UInt64, pairBytes: UInt64) -> UInt64 {
    guard consumed > tailStart else { return tailStart }
    return tailStart + (consumed - tailStart + pairBytes - 1) / pairBytes * pairBytes
}

/// A file opened for decoding.
private struct Track {
    var item: OutputItem
    let decoder: any TrackDecoder
    /// The rate its frames are counted at: the file's, or a DSD file's DoP carrier. The device
    /// runs at it unless the output converts.
    let sampleRateHz: Double
    let channels: UInt32
    /// The order the decoder hands the channels on in.
    let channelOrder: ChannelOrder
    /// The format the file holds, for the signal path.
    let file: SignalFormat
    /// Set for a DSD file, which plays as DoP at unity (ADR 0064).
    let isDoP: Bool
    /// The start of the track, decoded while the track before it drained.
    var predecoded: Predecoded?

    /// The length decoding should reach, in frames: the decoder's, except for an MP3, where
    /// AudioToolbox estimates it from the file size, so it's the length a Xing/Info or VBRI
    /// header states, or nil when there's none and the length can't be checked.
    let checkedLengthFrames: Int64?

    init(_ item: OutputItem, latency: FileLatency?) throws {
        self.item = item
        if dsdFileExtensions.contains(item.url.pathExtension.lowercased()) {
            let reader = try DSDReader(url: item.url)
            decoder = reader
            sampleRateHz = reader.carrierRateHz
            channels = UInt32(reader.stream.channels)
            file = SignalFormat(
                formatID: dsdFormatID, sampleRateHz: Double(reader.stream.rateHz),
                bitsPerChannel: 1, channels: channels, isFloat: false)
            isDoP = true
            // DoP is never converted, so its channels are never mixed.
            channelOrder = ChannelOrder(defaultFor: Int(channels), isAssumed: false)
            // A file cut short is a truncation warning from the scan; the reader plays the bits
            // present.
            checkedLengthFrames = nil
            return
        }
        let decoder = try FileDecoder(url: item.url, latency: latency)
        self.decoder = decoder
        sampleRateHz = decoder.fileFormat.mSampleRate
        channels = decoder.fileFormat.mChannelsPerFrame
        channelOrder = decoder.channelOrder
        file = SignalFormat(decoder.fileFormat)
        isDoP = false
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

    var durationSeconds: Double { Double(decoder.lengthFrames) / sampleRateHz }

    func frame(atSeconds seconds: Double) -> Int64 { clamped(Int64(seconds * sampleRateHz)) }

    /// DoP starts on a pair of frames, where the reader seeks to.
    func clamped(_ frame: Int64) -> Int64 {
        let clamped = min(max(0, frame), decoder.lengthFrames)
        return isDoP ? clamped & ~1 : clamped
    }

    func signal(into stream: RenderStream) -> TrackSignal {
        let decoded =
            isDoP
            ? SignalFormat(
                formatID: dopFormatID, sampleRateHz: sampleRateHz, bitsPerChannel: dopWordBits,
                channels: channels, isFloat: false)
            : SignalFormat(stream.writtenFormat)
        return TrackSignal(
            file: file, decoded: decoded, isConverted: stream.format.isConverted,
            channelOrderAssumed: channelOrder.isAssumed)
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

/// A track's place in the ring buffer. It keeps the track's file open, so a seek back into it
/// after decoding moved on doesn't open the file again, which on a NAS costs a round trip or two.
private struct Segment {
    let track: Track
    var item: OutputItem { track.item }
    /// The count of bytes written when its first byte went in.
    let startByte: UInt64
    /// Where in the file it starts, after a seek.
    let startSeconds: Double
    let durationSeconds: Double
    let signal: TrackSignal

    func info(_ stream: RenderStream) -> TrackInfo {
        TrackInfo(durationSeconds: durationSeconds, outputFormat: stream.outputFormat)
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

    /// Carries DoP, which the IO proc copies and never scales, so writes come in pairs of
    /// frames and every track starts on an even frame, where the markers expect it.
    let isDoP: Bool
    /// How DoP sits in the device's samples, for the tail; nil for PCM or a format DoP can't use,
    /// which the reader refuses.
    private let dopLayout: DoPLayout?
    /// The rate and channels of the tracks it was configured for, which the device runs at
    /// unless it converts.
    private let trackRateHz: Double
    private let trackChannels: ChannelOrder
    /// Set when the device converts to another rate or channel count, or to integers too narrow
    /// for the track, which it dithers. A conversion that loses nothing, such as integer to float,
    /// the decoder does itself.
    let converter: OutputConverter?
    /// `produced` when the converter's output last started from nothing.
    private var converterStart: UInt64 = 0
    /// The converter still holds the end of the last track, for the tail to write.
    private var converterTailDue = false

    /// `withGain` needs a sample layout the IO proc can scale.
    init(format: DeviceFormat, for track: Track, withGain: Bool) throws {
        let stream = format.stream
        let samples: HALRenderSampleKind
        isDoP = track.isDoP
        trackRateHz = track.sampleRateHz
        trackChannels = track.channelOrder
        if isDoP {
            samples = HALRenderSamplesOpaque
        } else if let kind = renderSampleKind(stream) {
            samples = kind
        } else if withGain {
            throw DeviceOutputError.noVolumeForFormat(format.summary)
        } else {
            // The gain stays at unity, so the IO proc never looks at the layout.
            samples = HALRenderSamplesInt32
        }
        self.format = format
        bytesPerFrame = Int(stream.mBytesPerFrame)
        dopLayout = isDoP ? DoPLayout(stream, channels: Int(stream.mChannelsPerFrame)) : nil
        var written = stream
        written.mFormatFlags &= ~kAudioFormatFlagIsNonMixable
        let physical = PhysicalFormat(written)
        let narrows = !physical.holdsSamples(
            Precision(file: track.file, decodedAs: physical.precision))
        converter =
            format.isConverted
                && (stream.mSampleRate != trackRateHz || stream.mChannelsPerFrame != track.channels
                    || narrows)
            ? try OutputConverter(
                from: trackRateHz, channels: trackChannels, to: written,
                dither: narrows && written.mFormatFlags & kAudioFormatFlagIsFloat == 0) : nil
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

    /// The format written to the ring buffer. Converters reject the non-mixable flag, which
    /// describes the hardware, not the samples.
    var writtenFormat: AudioStreamBasicDescription {
        var format = format.stream
        format.mFormatFlags &= ~kAudioFormatFlagIsNonMixable
        return format
    }

    /// The format to decode into.
    var decoderFormat: AudioStreamBasicDescription { converter?.inputFormat ?? writtenFormat }

    /// Whether `track` plays on in this stream: it has the rate and channels the stream was
    /// configured for, in the same order, so a converter carries on its signal and mix too.
    func fits(_ track: Track) -> Bool {
        track.sampleRateHz == trackRateHz && track.channelOrder == trackChannels
            && track.isDoP == isDoP
    }

    /// Decodes the next part of `track` into the chunk. Returns how many frames: 0 at its end.
    func decode(_ track: Track) throws -> UInt32 {
        let frames = UInt32(Self.chunkFrames)
        guard let converter else { return try track.decoder.read(into: chunk, frames: frames) }
        return try converter.convert(from: track.decoder, into: chunk, frames: frames)
    }

    /// Where the track about to be decoded starts, as a count of bytes written: after what's
    /// queued, or where its first frame lands in a converter that carries on from the last
    /// track. A converter that doesn't carry on starts again from there.
    func startTrack() throws -> UInt64 {
        let queuedEnd = produced + UInt64(chunkBytes - chunkOffset)
        guard let converter else { return queuedEnd }
        converterTailDue = false
        if let frame = converter.nextTrackStartFrame {
            return converterStart + UInt64(frame) * UInt64(bytesPerFrame)
        }
        try converter.reset()
        converterStart = queuedEnd
        return queuedEnd
    }

    func info(for track: Track) -> TrackInfo {
        TrackInfo(durationSeconds: track.durationSeconds, outputFormat: outputFormat)
    }

    /// The device and its format, as the status line shows it, and whether it carries DoP or
    /// a converted track.
    var outputFormat: String {
        if isDoP { return "\(format.shown), DoP" }
        return format.isConverted ? "\(format.shown), converted" : format.shown
    }

    var chunkIsEmpty: Bool { chunkOffset == chunkBytes }

    /// Frames of the DoP tail still to write.
    private(set) var tailFramesLeft = 0
    /// Whether a tail is due after the last track: DoP silence, or what a converter still holds.
    var hasTailToWrite: Bool { tailFramesLeft > 0 || converterTailDue }
    /// DoP's tail goes in at once. A converter's waits until what's queued has nearly played,
    /// since the engine can name the next track after the last one has been decoded, and a
    /// flushed converter can't carry its signal on into it.
    var tailIsDue: Bool {
        tailFramesLeft > 0 || (converterTailDue && RingBufferReadable(ring) <= prefillBytes)
    }
    /// Where the audio before the DoP tail ended, which the drain waits for; nil without one.
    private(set) var tailStart: UInt64?

    var audioEndByte: UInt64 { tailStart ?? produced }

    /// Queues the tail after what's written. A DoP tail starts on an even frame, as everything in
    /// a DoP stream does, so its markers carry on from the audio's. A converter's is the end of
    /// the last track, so the drain waits for it.
    func startTail() {
        if let converter {
            converterTailDue = !converter.isFlushing
            return
        }
        // One already queued stays: a second would move the end the drain waits for past it.
        guard dopLayout != nil, tailStart == nil else { return }
        let frames = Int(sampleRateHz * (format.latencySeconds + dopTailSeconds))
        tailFramesLeft = frames + frames % 2
        tailStart = produced
    }

    func clearTail() {
        tailFramesLeft = 0
        tailStart = nil
    }

    /// Drops everything queued from `boundary` on and keeps all before it: what's written, what's
    /// left of it in the chunk, and in a converted stream what the converter still holds of it,
    /// which a flush gives up. The audio after it then starts at `boundary`.
    func keep(upTo boundary: UInt64) throws {
        if produced >= boundary {
            HALRenderDiscard(render, boundary, produced)
            dropChunk()
        } else {
            let missing = Int(boundary - produced)
            let queued = chunkBytes - chunkOffset
            if queued >= missing {
                chunkBytes = chunkOffset + missing
            } else if let converter {
                precondition(
                    missing <= Self.chunkFrames * bytesPerFrame,
                    "a converter holds back less than the decode chunk")
                memmove(chunk, chunk + chunkOffset, queued)
                (chunkOffset, chunkBytes) = (0, queued)
                while chunkBytes < missing {
                    let frames = try converter.flush(
                        into: chunk + chunkBytes,
                        frames: UInt32((missing - chunkBytes) / bytesPerFrame))
                    if frames == 0 { break }
                    chunkBytes += Int(frames) * bytesPerFrame
                }
            }
        }
        try converter?.reset()
        converterTailDue = false
    }

    /// Gives up the tail after it failed.
    func dropTail() {
        clearTail()
        converterTailDue = false
    }

    /// Fills the chunk with the next part of the tail.
    func chunkTail() throws {
        if let converter, converterTailDue {
            let frames = try converter.flush(into: chunk, frames: UInt32(Self.chunkFrames))
            if frames == 0 { converterTailDue = false }
            chunkDecoded(frames: Int(frames))
            return
        }
        guard let dopLayout else { preconditionFailure("only DoP and converters have a tail") }
        let frames = min(tailFramesLeft, Self.chunkFrames)
        dopLayout.writeSilence(into: chunk, frames: frames)
        chunkDecoded(frames: frames)
        tailFramesLeft -= frames
    }

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

    /// Writes as many whole frames of the chunk as fit, in pairs for DoP, and returns how many
    /// bytes that was. Whole frames keep every count the IO proc and the boundaries use on a
    /// frame edge; pairs keep every track start and discard on an even frame.
    func writeChunk() -> Int {
        let space = RingBufferCapacity(ring) - RingBufferReadable(ring)
        let unit = bytesPerFrame * (isDoP ? 2 : 1)
        let count = RingBufferWrite(
            ring, chunk + chunkOffset, min(chunkBytes - chunkOffset, space - space % unit))
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
