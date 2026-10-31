import CoreAudio
import Foundation
import HALRender
import Log
import Playback
import RingBuffer

private let logger = moduleLogger()

public enum DeviceOutputError: Error, CustomStringConvertible {
    case outOfMemory
    case noVolumeForFormat(String)

    public var description: String {
        switch self {
        case .outOfMemory: "couldn't allocate the playback buffer"
        case .noVolumeForFormat(let format):
            "the digital volume can't scale samples in this device format: \(format)"
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
public final class DeviceOutput: Output, @unchecked Sendable {
    public let events: AsyncStream<OutputEvent>
    public let hasVolume: Bool
    private let continuation: AsyncStream<OutputEvent>.Continuation
    private let provider: any PCMDeviceProvider
    /// Guards `pending`, `published` and `isClosed`, and wakes the control thread.
    private let condition = NSCondition()
    private var pending: [Command] = []
    private var published: OutputPosition?
    private var isClosed = false

    // Everything below belongs to the control thread.
    private var device: (any PCMDevice)?
    private var stream: RenderStream?
    /// The tracks in the ring buffer, oldest first. The first is the one playing.
    private var segments: [Segment] = []
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
    private var gain = 1.0
    /// Streams whose IO proc may still be called because stopping it failed. They are never freed.
    private var retired: [RenderStream] = []

    /// `digitalVolume` turns on `setVolume`. Until it is used, samples still pass untouched.
    public init(provider: any PCMDeviceProvider, digitalVolume: Bool) throws {
        self.provider = provider
        hasVolume = digitalVolume
        (events, continuation) = AsyncStream.makeStream(of: OutputEvent.self)
        try provider.watch { [weak self] in self?.post(.devicesChanged) }
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
    public func position() -> OutputPosition? { condition.withLock { published } }

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
                    publishPosition()
                    continuation.finish()
                    done.signal()
                    return
                }
                perform(command)
            }
            service()
        }
    }

    /// How often to refill and look for track boundaries. The ring buffer holds seconds, so this
    /// only sets how late an event can be; with nothing loaded the thread sleeps until a command.
    private var tickSeconds: Double? {
        guard stream != nil else { return nil }
        return running ? 0.01 : 0.05
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
            if let stream { HALRenderSetGain(stream.render, Float(gain)) }
        case .devicesChanged: checkDevice()
        case .close: preconditionFailure("close is handled by the run loop")
        }
    }

    // MARK: Loading and seeking

    private func loadTrack(_ item: OutputItem, startSeconds: Double, playing: Bool) {
        unload()
        self.playing = playing
        let started = uptime()
        let track: Track
        do {
            track = try Track(item)
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
            stopIO()
            stream = nil
            // Stopping can fail the device, which has been reported.
            guard device != nil else { return }
            let stream: RenderStream
            do {
                stream = try configure(for: track)
                try feed(track, into: stream, atFrame: frame)
            } catch {
                cannotPlay(item, error)
                return
            }
            fill(stream, upTo: stream.prefillBytes)
            startIfReady()
            emit(
                .formatChanged(
                    item.id,
                    FormatChange(
                        from: from, to: stream.format.summary, switchSeconds: uptime() - started)))
        }
        if let stream { emit(.trackStarted(item.id, stream.info(for: track))) }
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
        let stream = try RenderStream(format: format, withGain: hasVolume)
        if hasVolume { HALRenderSetGain(stream.render, Float(gain)) }
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
                durationSeconds: track.durationSeconds))
        HALRenderSetDraining(stream.render, false)
        drainedAt = nil
    }

    /// Replaces everything queued with `track` from `frame`, without stopping the device: the IO
    /// proc discards what was written so far at the start of its next cycle. `continuingFrom` is
    /// the consumed count `frame` was read at, when the new audio carries on from there.
    private func restart(
        _ stream: RenderStream, with track: Track, atFrame frame: Int64,
        continuingFrom: UInt64 = HALRenderNoContinuation
    ) throws {
        HALRenderDiscardBefore(stream.render, stream.produced, continuingFrom)
        segments = []
        pendingSwitch = nil
        try feed(track, into: stream, atFrame: frame)
        fill(stream, upTo: stream.prefillBytes)
    }

    private func seekTrack(toSeconds seconds: Double) {
        guard let stream else { return }
        seekTrack(toFrame: Int64(seconds * stream.sampleRateHz))
    }

    private func seekTrack(
        toFrame frame: Int64, continuingFrom: UInt64 = HALRenderNoContinuation
    ) {
        guard let stream, let current = segments.first else { return }
        do {
            // Whatever was queued after the current track goes back to being the next track.
            if let committed = try committedNext() { next = committed }
            let track = try reusableTrack(for: current.item)
            try restart(
                stream, with: track, atFrame: track.clamped(frame), continuingFrom: continuingFrom)
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
        guard let stream, let current = segments.first else { return }
        if segments.count > 1 || pendingSwitch != nil {
            // The old next track is already queued: drop it by seeking to the frame playing now.
            // The IO proc skips whatever it plays between this read and the discard, so the track
            // carries on without a gap or a repeat.
            let consumed = HALRenderConsumedBytes(stream.render)
            seekTrack(toFrame: positionFrame(consumed: consumed), continuingFrom: consumed)
            if segments.first?.item.id != current.item.id { return }
        }
        next = nil
        guard let item else { return }
        do {
            next = try Track(item)
        } catch {
            emit(.trackFailed(item.id, error))
            return
        }
        if feeding == nil, pendingSwitch == nil { advanceFeed(stream) }
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
            pendingSwitch = next
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

    private func service() {
        guard let stream else {
            publishPosition()
            return
        }
        if stream.isHalfEmpty { fill(stream) }
        let consumed = HALRenderConsumedBytes(stream.render)
        while segments.count > 1, consumed >= segments[1].startByte {
            let ended = segments.removeFirst()
            emit(.trackEnded(ended.item.id))
            emit(.trackStarted(segments[0].item.id, segments[0].info(stream)))
        }
        if let frames = stream.newUnderrunFrames() { emit(.underrun(frames: frames)) }
        if running, feeding == nil, consumed >= stream.produced {
            drained(stream)
        } else {
            drainedAt = nil
        }
        publishPosition()
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
        stopIO()
        self.stream = nil
        guard device != nil else { return }
        let next: RenderStream
        do {
            next = try configure(for: track)
            try feed(track, into: next, atFrame: 0)
        } catch {
            emit(.trackFailed(track.item.id, error))
            unload()
            closeDevice()
            if let last { emit(.finished(last.id)) }
            return
        }
        fill(next, upTo: next.prefillBytes)
        startIfReady()
        emit(
            .formatChanged(
                track.item.id,
                FormatChange(from: from, to: next.format.summary, switchSeconds: uptime() - since)))
        emit(.trackStarted(track.item.id, next.info(for: track)))
    }

    // MARK: The device

    private func startIfReady() {
        guard playing, !running, let device, let stream else { return }
        do {
            try device.start(stream.render)
            running = true
        } catch {
            fail(error)
        }
    }

    private func stopIO() {
        guard running, let device, let stream else { return }
        running = false
        do {
            try device.stop()
        } catch {
            retired.append(stream)
            fail(error)
        }
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
        if let device {
            guard !provider.isConnected() else { return }
            let item = segments.first?.item.id
            let seconds = positionSeconds() ?? 0
            device.abandon()
            self.device = nil
            running = false
            stream = nil
            unload()
            deviceMissing = true
            logger.error("\(self.provider.deviceName) went away")
            emit(.deviceLost(item, positionSeconds: seconds))
        } else if deviceMissing, provider.isConnected() {
            deviceMissing = false
            provider.deviceReturned()
            emit(.deviceReturned)
        }
    }

    // MARK: Position and events

    /// The frame of the current track the IO proc had reached when it had consumed `consumed`.
    private func positionFrame(consumed: UInt64) -> Int64 {
        guard let stream, let segment = segments.first else { return 0 }
        let played =
            consumed > segment.startByte
            ? Int64((consumed - segment.startByte) / UInt64(stream.bytesPerFrame)) : 0
        return segment.startFrame + played
    }

    private func positionSeconds() -> Double? {
        guard let stream, !segments.isEmpty else { return nil }
        return Double(positionFrame(consumed: HALRenderConsumedBytes(stream.render)))
            / stream.sampleRateHz
    }

    private func publishPosition() {
        let position = segments.first.flatMap { segment in
            positionSeconds().map { OutputPosition(item: segment.item.id, seconds: $0) }
        }
        condition.withLock { published = position }
    }

    private func emit(_ event: OutputEvent) { continuation.yield(event) }
}

private func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

/// A file opened for decoding.
private struct Track {
    let item: OutputItem
    let decoder: FileDecoder

    init(_ item: OutputItem) throws {
        self.item = item
        decoder = try FileDecoder(url: item.url)
    }

    var sampleRateHz: Double { decoder.fileFormat.mSampleRate }
    var channels: UInt32 { decoder.fileFormat.mChannelsPerFrame }
    var durationSeconds: Double { Double(decoder.lengthFrames) / sampleRateHz }

    func frame(atSeconds seconds: Double) -> Int64 { clamped(Int64(seconds * sampleRateHz)) }

    func clamped(_ frame: Int64) -> Int64 { min(max(0, frame), decoder.lengthFrames) }
}

/// A track's place in the ring buffer.
private struct Segment {
    let item: OutputItem
    /// The count of bytes written when its first byte went in.
    let startByte: UInt64
    /// The frame of the file it starts at, after a seek.
    let startFrame: Int64
    let durationSeconds: Double

    func info(_ stream: RenderStream) -> TrackInfo {
        TrackInfo(durationSeconds: durationSeconds, outputFormat: stream.format.summary)
    }
}

/// The ring buffer and render state for one device format, and the decode chunk that feeds them.
private final class RenderStream {
    static let chunkFrames = 32768
    /// Four seconds of audio. The control thread refills it every 10 ms, so nearly all of it is
    /// margin: for a NAS read that stalls, and for opening the next track on the same thread
    /// while this drains. A seek doesn't wait for it to empty (`HALRenderDiscardBefore`), so its
    /// size costs memory, not responsiveness: 1.4 MB at 44.1 kHz stereo 32-bit, 6 MB at 192 kHz,
    /// 24 MB at 768 kHz, each rounded up to a power of two.
    static let bufferSeconds = 4.0
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

    /// Frames of underrun since the last call, or nil when there were none.
    func newUnderrunFrames() -> Int? {
        let bytes = HALRenderUnderrunBytes(render)
        guard bytes > reportedUnderrunBytes else { return nil }
        defer { reportedUnderrunBytes = bytes }
        return Int(bytes - reportedUnderrunBytes) / bytesPerFrame
    }
}
