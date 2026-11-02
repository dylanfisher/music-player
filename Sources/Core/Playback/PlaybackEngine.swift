import Foundation
import Log

private let logger = moduleLogger()

/// The queue and transport, driving one `Output`. Every change goes out on `updates()`, which the
/// UI, media keys and remote all read.
public actor PlaybackEngine {
    public private(set) var state = PlaybackState()
    private var output: any Output
    /// The outputs whose events are read, each once, by identity. Only the current one's count.
    private var reading: Set<ObjectIdentifier> = []
    private let shuffled: @Sendable ([Int]) -> [Int]
    private var queue = PlayQueue()
    private var subscribers: [UUID: AsyncStream<PlaybackUpdate>.Continuation] = [:]
    private var lastItemID: OutputItem.ID = 0
    /// What the output has loaded, and what it has been told comes next, as positions in the
    /// queue's play order.
    private var currentItem: (id: OutputItem.ID, position: Int)?
    /// Mirrors what the output was last told comes next. `entry` is the index into the queue, so
    /// a change of order that leaves the same track next isn't sent again.
    private var nextItem: (id: OutputItem.ID, position: Int, entry: Int)?
    /// Set when the current item failed, so its end skips on rather than repeating it.
    private var currentFailed = false
    /// Where to pick up after the device was lost, since the output dropped everything.
    private var resumeSeconds: Double?
    /// Tracks that failed since one last started; once it reaches the queue's length, nothing in
    /// it plays and the engine stops instead of trying them all again.
    private var failuresInARow = 0
    /// The position `play()` starts from when nothing is loaded.
    private var cursor = 0
    /// "Previous" within this many seconds of a track's start goes back a track; later, it
    /// restarts the track.
    private static let restartThresholdSeconds = 3.0

    /// `shuffled` returns its argument in a random order; tests pass a fixed one.
    public init(
        output: any Output, shuffled: @escaping @Sendable ([Int]) -> [Int] = { $0.shuffled() }
    ) {
        self.output = output
        self.shuffled = shuffled
        reading.insert(ObjectIdentifier(output))
        Self.read(output, into: self)
    }

    /// Hands `output`'s events to the engine as they come, for as long as it's open.
    private nonisolated static func read(_ output: any Output, into engine: PlaybackEngine) {
        let events = output.events
        let id = ObjectIdentifier(output)
        Task { [weak engine] in
            for await event in events {
                await engine?.handle(event, from: id)
            }
            await engine?.closed(id)
        }
    }

    /// The current output has closed, so nothing will change again; another one closing
    /// changes nothing.
    private func closed(_ id: ObjectIdentifier) {
        reading.remove(id)
        if id == ObjectIdentifier(output) { finishUpdates() }
    }

    /// Plays through `newOutput` from now on: what's loaded moves to it at the position it had,
    /// playing or paused as it was, and the old output is stopped. Events from any output but
    /// the current one are ignored, so the old one can stay open to be used again.
    public func use(_ newOutput: any Output) {
        guard newOutput !== output else { return }
        let resume = currentItem.map { ($0.position, resumeSeconds ?? position() ?? 0) }
        unload()
        output = newOutput
        if reading.insert(ObjectIdentifier(newOutput)).inserted {
            Self.read(newOutput, into: self)
        }
        guard let (position, seconds) = resume else { return }
        load(position, startSeconds: seconds, playing: state.status == .playing)
    }

    /// Every change from now on, starting with the current state.
    public func updates() -> AsyncStream<PlaybackUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: PlaybackUpdate.self, bufferingPolicy: .bufferingNewest(256))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
        continuation.yield(PlaybackUpdate(state: state, event: nil, positionSeconds: position()))
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    /// The output has closed, so nothing will change again.
    private func finishUpdates() {
        for continuation in subscribers.values { continuation.finish() }
        subscribers = [:]
    }

    /// Stops playback and replaces the queue. `first` is the index `play()` starts at.
    public func setQueue(_ urls: [URL], first: Int = 0) {
        unload()
        failuresInARow = 0
        cursor = queue.replace(with: urls, first: first, shuffled: shuffled) ?? 0
        state.queue = urls
        state.order = queue.order
        state.currentIndex = urls.isEmpty ? nil : queue.entry(at: cursor)
        state.status = .stopped
        publish(.queueChanged)
    }

    public func play() {
        switch state.status {
        case .playing: return
        case .paused where currentItem != nil && resumeSeconds == nil:
            output.play()
        case .paused, .stopped:
            guard !queue.order.isEmpty else { return }
            failuresInARow = 0
            load(currentItem?.position ?? cursor, startSeconds: resumeSeconds ?? 0, playing: true)
        }
        state.status = .playing
        publish(.resumed)
    }

    public func pause() {
        guard state.status == .playing else { return }
        output.pause()
        state.status = .paused
        publish(.paused)
    }

    public func togglePause() {
        state.status == .playing ? pause() : play()
    }

    public func stop() {
        guard state.status != .stopped else { return }
        if let currentItem { cursor = currentItem.position }
        unload()
        state.status = .stopped
        publish(.stopped)
    }

    public func next() {
        guard let from = currentItem?.position ?? (queue.order.isEmpty ? nil : cursor) else {
            return
        }
        guard let position = queue.position(after: from, natural: false) else {
            stop()
            return
        }
        move(to: position)
    }

    public func previous() {
        guard let from = currentItem?.position ?? (queue.order.isEmpty ? nil : cursor) else {
            return
        }
        if let seconds = position(), seconds > Self.restartThresholdSeconds {
            seek(toSeconds: 0)
        } else if let position = queue.position(before: from) {
            move(to: position)
        } else {
            seek(toSeconds: 0)
        }
    }

    /// Loads the track at `position`, playing if playback was, or just points the queue at it when
    /// stopped.
    private func move(to position: Int) {
        failuresInARow = 0
        switch state.status {
        case .stopped:
            cursor = position
            state.currentIndex = queue.entry(at: position)
            publish(.queueChanged)
        case .playing, .paused:
            load(position, startSeconds: 0, playing: state.status == .playing)
        }
    }

    public func seek(toSeconds seconds: Double) {
        guard currentItem != nil else { return }
        let seconds = max(0, seconds)
        if resumeSeconds != nil {
            resumeSeconds = seconds
        } else {
            output.seek(toSeconds: seconds)
        }
        publish(.seeked(seconds: seconds))
    }

    public func setRepeat(_ mode: RepeatMode) {
        guard mode != queue.repeatMode else { return }
        queue.repeatMode = mode
        state.repeatMode = mode
        sendNext()
        publish(.repeatChanged)
    }

    public func setShuffle(_ on: Bool) {
        guard on != queue.shuffle else { return }
        let position = queue.setShuffle(
            on, keeping: currentItem?.position ?? (queue.order.isEmpty ? nil : cursor),
            shuffled: shuffled)
        if let position {
            if let id = currentItem?.id { currentItem = (id, position) } else { cursor = position }
        }
        state.shuffle = on
        state.order = queue.order
        sendNext()
        publish(.shuffleChanged)
    }

    // MARK: Queue edits. Positions count through `state.order`.

    /// Plays the track at `position` in play order now.
    public func play(at position: Int) {
        guard queue.order.indices.contains(position) else { return }
        move(to: position)
        play()
    }

    /// Queues `urls` to play straight after the current track, or after the one `play()` would
    /// start with.
    public func playNext(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let after = queue.order.isEmpty ? -1 : (currentItem?.position ?? cursor)
        applyEdit(queue.insert(urls, at: after + 1))
    }

    /// Moves the tracks at `positions` to just before `destination`, counted before the move.
    public func moveQueueItems(_ positions: IndexSet, to destination: Int) {
        guard (0...queue.order.count).contains(destination) else { return }
        applyEdit(queue.move(positions, to: destination))
    }

    /// Removes the tracks at `positions`. Removing the current track moves on to the one after it,
    /// as `next()` would, or stops when none is left.
    public func removeQueueItems(_ positions: IndexSet) {
        applyEdit(queue.remove(positions))
    }

    /// Follows the current, next and starting tracks to their new positions after an edit.
    private func applyEdit(_ moved: [Int?]) {
        state.queue = queue.entries
        state.order = queue.order
        if let nextItem {
            if let position = moved[nextItem.position] {
                self.nextItem = (nextItem.id, position, queue.entry(at: position))
            } else {
                // Gone from the queue, but the output still has it: `sendNext` replaces it.
                self.nextItem = (nextItem.id, -1, -1)
            }
        }
        if let current = currentItem {
            if let position = moved[current.position] {
                currentItem = (current.id, position)
                cursor = position
                state.currentIndex = queue.entry(at: position)
                sendNext()
            } else if let following = moved[(current.position + 1)...].lazy.compactMap({ $0 })
                .first
            {
                load(following, startSeconds: 0, playing: state.status == .playing)
            } else {
                cursor = 0
                unload()
                state.status = .stopped
                state.currentIndex = queue.order.isEmpty ? nil : queue.entry(at: 0)
            }
        } else {
            cursor =
                moved.indices.contains(cursor)
                ? moved[cursor] ?? moved[cursor...].lazy.compactMap({ $0 }).first ?? 0 : 0
            state.currentIndex = queue.order.isEmpty ? nil : queue.entry(at: cursor)
        }
        publish(.queueChanged)
    }

    /// Linear amplitude from 0 to 1, for outputs that have a volume.
    public func setVolume(_ gain: Double) throws {
        guard output.hasVolume else { throw PlaybackError.noVolume }
        output.setVolume(gain)
    }

    /// Seconds into the current track, or nil when nothing is loaded.
    public func position() -> Double? {
        if let resumeSeconds { return resumeSeconds }
        guard let position = output.position(),
            position.item == currentItem?.id || position.item == nextItem?.id
        else { return nil }
        return position.seconds
    }

    private func load(_ position: Int, startSeconds: Double, playing: Bool) {
        lastItemID += 1
        currentItem = (lastItemID, position)
        nextItem = nil
        currentFailed = false
        resumeSeconds = nil
        cursor = position
        state.currentIndex = queue.entry(at: position)
        state.durationSeconds = nil
        output.load(
            OutputItem(id: lastItemID, url: queue.url(at: position)), startSeconds: startSeconds,
            playing: playing)
        sendNext()
    }

    /// Tells the output what follows the current item as the queue stands now, unless it already
    /// has that track: replacing a next track the output has queued costs it work.
    private func sendNext() {
        guard let currentItem, resumeSeconds == nil else { return }
        guard let position = queue.position(after: currentItem.position, natural: true) else {
            guard nextItem != nil else { return }
            nextItem = nil
            output.setNext(nil)
            return
        }
        let entry = queue.entry(at: position)
        if let nextItem, nextItem.entry == entry {
            self.nextItem = (nextItem.id, position, entry)
            return
        }
        handOver(position)
    }

    /// Makes the track at `position` the output's next one.
    private func handOver(_ position: Int) {
        lastItemID += 1
        nextItem = (lastItemID, position, queue.entry(at: position))
        output.setNext(OutputItem(id: lastItemID, url: queue.url(at: position)))
    }

    private func unload() {
        if currentItem != nil || resumeSeconds != nil { output.stop() }
        currentItem = nil
        nextItem = nil
        resumeSeconds = nil
        state.durationSeconds = nil
    }

    private func handle(_ event: OutputEvent, from id: ObjectIdentifier) {
        guard id == ObjectIdentifier(output) else { return }
        handle(event)
    }

    func handle(_ event: OutputEvent) {
        switch event {
        case .trackStarted(let id, let info):
            if let nextItem, id == nextItem.id {
                currentItem = (nextItem.id, nextItem.position)
                self.nextItem = nil
                currentFailed = false
                sendNext()
            } else if id != currentItem?.id {
                return
            }
            failuresInARow = 0
            let index = queue.entry(at: currentItem!.position)
            state.currentIndex = index
            state.durationSeconds = info.durationSeconds
            state.outputFormat = info.outputFormat
            state.device = .connected
            publish(.trackStarted(index: index))
        case .trackEnded(let id):
            guard let currentItem, id == currentItem.id else { return }
            publish(.trackEnded(index: queue.entry(at: currentItem.position)))
        case .formatChanged(let id, let change):
            guard id == currentItem?.id || id == nextItem?.id else { return }
            state.outputFormat = change.to
            publish(.formatChanged(change))
        case .trackFailed(let id, let error):
            let failed: Int
            if let currentItem, id == currentItem.id {
                failed = currentItem.position
                currentFailed = true
            } else if let nextItem, id == nextItem.id {
                failed = nextItem.position
            } else {
                return
            }
            failuresInARow += 1
            logger.error("\(self.queue.url(at: failed).path): \(error)")
            publish(.trackFailed(queue.url(at: failed), reason: "\(error)"))
            if id == nextItem?.id { skip(after: failed) }
        case .finished(let id):
            guard let currentItem, id == currentItem.id else { return }
            if currentFailed {
                self.nextItem = nil
                skip(after: currentItem.position)
                if let nextItem {
                    load(nextItem.position, startSeconds: 0, playing: state.status == .playing)
                    return
                }
            } else if let nextItem {
                // The output ran out before it saw the next item.
                load(nextItem.position, startSeconds: 0, playing: state.status == .playing)
                return
            }
            cursor = 0
            self.currentItem = nil
            self.nextItem = nil
            state.currentIndex = queue.order.isEmpty ? nil : queue.entry(at: 0)
            state.status = .stopped
            state.durationSeconds = nil
            publish(.finished)
        case .underrun(let frames):
            publish(.underrun(frames: frames))
        case .deviceLost(let id, let seconds):
            // The output may have moved on to the next item before the engine heard it start.
            if let nextItem, id == nextItem.id {
                currentItem = (nextItem.id, nextItem.position)
                cursor = nextItem.position
                state.currentIndex = nextItem.entry
            }
            if let currentItem, id == currentItem.id {
                resumeSeconds = seconds
            } else if currentItem != nil {
                resumeSeconds = 0
            }
            nextItem = nil
            if state.status == .playing { state.status = .paused }
            state.device = .lost
            publish(.deviceLost)
        case .deviceReturned:
            guard state.device == .lost else { return }
            state.device = .returned
            publish(.deviceReturned)
        case .seekFailed(let id, let seconds):
            guard id == currentItem?.id else { return }
            logger.error("a seek failed; playback stays at \(seconds) s")
            publish(.seeked(seconds: seconds))
        case .transportChanged(let id, let playing):
            guard id == currentItem?.id, resumeSeconds == nil else { return }
            if playing, state.status == .paused {
                state.status = .playing
                publish(.resumed)
            } else if !playing, state.status == .playing {
                state.status = .paused
                publish(.paused)
            }
        case .failed(let id, let error):
            guard id == nil || id == currentItem?.id || id == nextItem?.id else { return }
            if let currentItem { cursor = currentItem.position }
            currentItem = nil
            nextItem = nil
            resumeSeconds = nil
            state.status = .stopped
            logger.error("output failed: \(error)")
            publish(.failed(reason: "\(error)"))
        }
    }

    /// Points `next` past a track that failed. Gives up once every track in the queue has failed
    /// in a row, so a queue of unplayable files ends instead of looping.
    private func skip(after position: Int) {
        guard failuresInARow < queue.order.count,
            let following = queue.position(after: position, natural: false)
        else {
            nextItem = nil
            output.setNext(nil)
            return
        }
        handOver(following)
    }

    private func publish(_ event: PlaybackEvent) {
        let update = PlaybackUpdate(state: state, event: event, positionSeconds: position())
        for continuation in subscribers.values { continuation.yield(update) }
    }
}
