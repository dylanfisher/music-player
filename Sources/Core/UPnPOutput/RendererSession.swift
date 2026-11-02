import Foundation
import LocalNetwork
import Log
import Playback
import UPnP

private let logger = moduleLogger()

/// One thing for the session to do, in the order the output was asked.
enum RendererWork: Sendable {
    case load(OutputItem, startSeconds: Double, playing: Bool)
    case setNext(OutputItem?)
    case play, pause, stop
    case seek(Double)
    case poll
}

/// Plays to one renderer: runs each command and each poll to the end before the next, so
/// replies can't interleave, on the task `RendererOutput` starts, never the main thread
/// (ADR 0041). Every renderer reply is hostile: each action is under the client's caps and a
/// deadline, and a renderer that stops answering is reported as lost.
actor RendererSession {
    /// Polls in a row that fail before the renderer counts as gone.
    static let lostAfterPolls = 3
    /// Polls in a row that find it stopped, after Play, before it counts as refusing the track.
    static let notStartingPolls = 5
    /// How close to its end a track that stopped must have been to count as played out: the
    /// renderer resets its position when it stops, so the last one polled is all there is.
    static let endSlackSeconds = 3.0

    private final class Loaded {
        let item: OutputItem
        let track: RendererTrack
        let uri: String
        /// What the engine asked for, as opposed to what the renderer says.
        var playing: Bool
        /// The renderer has said it's playing or paused this track, so a stop means it ended.
        var started = false
        var stoppedPolls = 0
        /// Where to seek once the renderer has the track playing or paused.
        var pendingSeek: Double?
        /// The track's length as the renderer last gave it, which decides whether a stop came
        /// at the end; the file's own length until it says.
        var durationSeconds: Double

        init(_ item: OutputItem, _ track: RendererTrack, uri: String, playing: Bool) {
            self.item = item
            self.track = track
            self.uri = uri
            self.playing = playing
            durationSeconds = track.durationSeconds
        }
    }

    private struct Next {
        let item: OutputItem
        let track: RendererTrack
        let uri: String
        /// Whether `SetNextAVTransportURI` gave it to the renderer.
        var sent: Bool
    }

    private let renderer: Renderer
    private let control: AVTransportControl
    private let serverInterface: NetworkInterface
    private let shared: RendererShared
    private let emit: @Sendable (OutputEvent) -> Void
    private let publish: @Sendable (SignalPath) -> Void
    private let now: @Sendable () -> Double
    private var server: HTTPServer<OutputItem.ID>?
    private var current: Loaded?
    private var next: Next?
    private var gapless = RendererGapless.unknown
    private var failedPolls = 0

    init(
        renderer: Renderer, control: AVTransportControl, serverInterface: NetworkInterface,
        shared: RendererShared, emit: @escaping @Sendable (OutputEvent) -> Void,
        publish: @escaping @Sendable (SignalPath) -> Void, now: @escaping @Sendable () -> Double
    ) {
        self.renderer = renderer
        self.control = control
        self.serverInterface = serverInterface
        self.shared = shared
        self.emit = emit
        self.publish = publish
        self.now = now
    }

    func run(_ work: RendererWork) async {
        switch work {
        case .load(let item, let startSeconds, let playing):
            await load(item, startSeconds: startSeconds, playing: playing)
        case .setNext(let item): await setNext(item)
        case .play: await play()
        case .pause: await pause()
        case .stop: await stop()
        case .seek(let seconds): await seek(seconds)
        case .poll:
            shared.pollDone()
            await poll()
        }
    }

    /// The path as it stands, for the panel.
    func signalPath() -> SignalPath {
        SignalPath(
            track: current.map { TrackSignal(file: $0.track.signal, decoded: $0.track.signal) },
            sink: .renderer(
                RendererSink(
                    name: renderer.name, address: "\(renderer.address)",
                    contentType: current?.track.contentType, gapless: gapless,
                    volumeIsReceivers: renderer.isDenonReceiver)))
    }

    // MARK: Commands

    private func load(_ item: OutputItem, startSeconds: Double, playing: Bool) async {
        drop()
        let prepared: (RendererTrack, String)
        do throws(RendererOutputError) {
            prepared = try await prepare(item)
        } catch {
            emit(.trackFailed(item.id, error))
            emit(.finished(item.id))
            release()
            return
        }
        await learnGapless()
        let (track, uri) = prepared
        do throws(SOAPProblem) {
            try await control.send(
                AVTransport.setURI(uri, metadata: track.metadata.document(url: uri)))
            if playing { try await control.send(AVTransport.play) }
        } catch {
            fail(item, error, at: startSeconds, finishing: true)
            return
        }
        let loaded = Loaded(item, track, uri: uri, playing: playing)
        if startSeconds > 0 { loaded.pendingSeek = startSeconds }
        current = loaded
        setPosition(loaded, startSeconds, advancing: false)
        emit(
            .trackStarted(
                item.id, TrackInfo(durationSeconds: track.durationSeconds, outputFormat: nil)))
        publish(signalPath())
    }

    private func setNext(_ item: OutputItem?) async {
        guard current != nil else { return }
        let wasSent = next?.sent == true
        if let old = next { shared.unserve(old.item.id) }
        next = nil
        guard let item else {
            if wasSent { await send(AVTransport.setNextURI("", metadata: "")) }
            return
        }
        let track: RendererTrack
        let uri: String
        do throws(RendererOutputError) {
            (track, uri) = try await prepare(item)
        } catch {
            emit(.trackFailed(item.id, error))
            return
        }
        var pending = Next(item: item, track: track, uri: uri, sent: false)
        if case .nextURI = gapless {
            do throws(SOAPProblem) {
                try await control.send(
                    AVTransport.setNextURI(uri, metadata: track.metadata.document(url: uri)))
                pending.sent = true
            } catch {
                if case .unreachable = error, let current {
                    return lose(current, error)
                }
                gapless = .afterStop("\(AVTransport.setNextURIAction) was refused: \(error)")
                logger.error(
                    "\(self.renderer.name): \(error); each track now starts after the last")
                publish(signalPath())
            }
        }
        next = pending
    }

    private func play() async {
        guard let current, !current.playing else { return }
        guard await send(AVTransport.play) else { return }
        current.playing = true
        setPosition(current, elapsed, advancing: current.started)
    }

    private func pause() async {
        guard let current, current.playing else { return }
        let seconds = elapsed
        guard await send(AVTransport.pause) else { return }
        current.playing = false
        setPosition(current, seconds, advancing: false)
    }

    private func seek(_ seconds: Double) async {
        guard let current else { return }
        let target = min(max(0, seconds), current.track.durationSeconds)
        if current.started {
            guard await send(AVTransport.seek(toSeconds: target)) else { return }
        } else {
            current.pendingSeek = target
        }
        setPosition(current, target, advancing: current.playing && current.started)
    }

    /// A renderer that doesn't answer a Stop isn't reported lost: nothing is playing to lose.
    private func stop() async {
        guard current != nil else { return }
        do throws(SOAPProblem) {
            try await control.send(AVTransport.stop)
        } catch {
            logger.error("\(self.renderer.name): \(error)")
        }
        release()
    }

    /// Sends `action` for the track loaded now. A renderer that doesn't answer is lost; one
    /// that refuses is logged, and what's loaded stays. False unless it was done.
    @discardableResult
    private func send(_ action: SOAPAction) async -> Bool {
        do throws(SOAPProblem) {
            try await control.send(action)
            return true
        } catch {
            if case .unreachable = error, let current {
                lose(current, error)
            } else {
                logger.error("\(self.renderer.name): \(error)")
            }
            return false
        }
    }

    // MARK: Polling

    private func poll() async {
        guard let current else { return }
        let transport: TransportInfo
        let position: PositionInfo
        do throws(SOAPProblem) {
            transport = try await control.transportInfo()
            position = try await control.positionInfo()
        } catch {
            failedPolls += 1
            logger.notice("\(self.renderer.name) didn't answer a poll: \(error)")
            if failedPolls >= Self.lostAfterPolls, self.current === current {
                lose(current, error)
            }
            return
        }
        failedPolls = 0
        // Commands may have run while the poll waited; only a reply about the same track counts.
        guard self.current === current else { return }
        if !position.trackURI.isEmpty, position.trackURI != current.uri {
            guard let next, next.sent, position.trackURI == next.uri else {
                emit(
                    .failed(
                        current.item.id,
                        RendererOutputError.playingSomethingElse(renderer: renderer.name)))
                return release()
            }
            return advance(from: current, to: next, gapless: true)
        }
        switch transport.state {
        case .playing, .paused:
            current.started = true
            current.stoppedPolls = 0
            if let duration = position.durationSeconds, duration > 0 {
                current.durationSeconds = duration
            }
            if let target = current.pendingSeek {
                current.pendingSeek = nil
                guard await send(AVTransport.seek(toSeconds: target)) else { return }
                setPosition(current, target, advancing: transport.state == .playing)
            } else if let seconds = position.seconds {
                setPosition(current, seconds, advancing: transport.state == .playing)
            }
            if !transport.isOK {
                logger.notice("\(self.renderer.name) reports an error while playing")
            }
        case .stopped, .noMedia:
            await stopped(current, transportOK: transport.isOK)
        case .transitioning, .other:
            break
        }
    }

    /// The renderer has stopped: the track played out, or never started, or someone stopped it.
    private func stopped(_ current: Loaded, transportOK: Bool) async {
        guard current.playing else { return }
        // A track that failed is finished, so the engine skips past it to what comes next.
        if !transportOK {
            emit(
                .trackFailed(
                    current.item.id, RendererOutputError.transportError(renderer: renderer.name)))
            emit(.finished(current.item.id))
            return release()
        }
        guard current.started else {
            current.stoppedPolls += 1
            guard current.stoppedPolls >= Self.notStartingPolls else { return }
            emit(
                .trackFailed(
                    current.item.id,
                    RendererOutputError.stoppedWithoutPlaying(
                        renderer: renderer.name, contentType: current.track.contentType)))
            emit(.finished(current.item.id))
            return release()
        }
        guard elapsed + Self.endSlackSeconds >= current.durationSeconds else {
            emit(
                .failed(
                    current.item.id, RendererOutputError.stoppedOnRenderer(renderer: renderer.name))
            )
            return release()
        }
        if next?.sent == true {
            gapless = .afterStop("it stopped instead of playing the next track it was given")
            logger.error("\(self.renderer.name) stopped instead of playing the next track")
        }
        await ended(current)
    }

    /// `current` is over: the next track starts with set-URI and Play, after a gap, or nothing
    /// is left.
    private func ended(_ current: Loaded) async {
        guard let next else {
            emit(.trackEnded(current.item.id))
            emit(.finished(current.item.id))
            return release()
        }
        let stoppedAt = now()
        self.next = nil
        do throws(SOAPProblem) {
            try await control.send(
                AVTransport.setURI(next.uri, metadata: next.track.metadata.document(url: next.uri)))
            try await control.send(AVTransport.play)
        } catch {
            emit(.trackEnded(current.item.id))
            return fail(next.item, error, at: 0, finishing: true)
        }
        logger.notice(
            "\(self.renderer.name): a gap of \(self.now() - stoppedAt) s, plus up to a poll, between tracks"
        )
        advance(from: current, to: next, gapless: false)
    }

    private func advance(from current: Loaded, to next: Next, gapless: Bool) {
        emit(.trackEnded(current.item.id))
        shared.unserve(current.item.id)
        let loaded = Loaded(next.item, next.track, uri: next.uri, playing: true)
        loaded.started = gapless
        self.current = loaded
        self.next = nil
        setPosition(loaded, 0, advancing: gapless)
        emit(
            .trackStarted(
                next.item.id,
                TrackInfo(durationSeconds: next.track.durationSeconds, outputFormat: nil)))
        publish(signalPath())
    }

    // MARK: Losing and releasing

    /// An action on `item` failed: the renderer is gone if it didn't answer, otherwise it
    /// refused the track.
    private func fail(_ item: OutputItem, _ error: SOAPProblem, at seconds: Double, finishing: Bool)
    {
        if case .unreachable = error {
            emit(.deviceLost(item.id, positionSeconds: seconds))
        } else {
            emit(
                .trackFailed(
                    item.id, RendererOutputError.refused(renderer: renderer.name, "\(error)")))
            if finishing { emit(.finished(item.id)) }
        }
        release()
    }

    private func lose(_ current: Loaded, _ error: SOAPProblem) {
        logger.error("\(self.renderer.name) is gone: \(error)")
        emit(.deviceLost(current.item.id, positionSeconds: elapsed))
        release()
    }

    /// Forgets what's loaded but keeps the server, for a load that replaces it.
    private func drop() {
        current = nil
        next = nil
        failedPolls = 0
        shared.unserveAll()
        shared.setPosition(nil)
    }

    /// Nothing is loaded: the server stops, so nothing on the network can fetch a file.
    private func release() {
        drop()
        server = nil
        shared.stopServer()
        publish(signalPath())
    }

    // MARK: Helpers

    /// Reads `item`'s file, offers it under a type the renderer takes, and serves it by token.
    private func prepare(_ item: OutputItem) async throws(RendererOutputError) -> (
        RendererTrack, String
    ) {
        let track = try RendererTrack.read(item.url, for: renderer)
        let server = try await startServer()
        shared.serve(item.id, HTTPServedFile(path: track.path, contentType: track.contentType))
        return (track, server.url(for: item.id))
    }

    private func startServer() async throws(RendererOutputError) -> HTTPServer<OutputItem.ID> {
        if let server { return server }
        let shared = shared
        let name = renderer.name
        let started: HTTPServer<OutputItem.ID>
        do throws(LocalNetworkError) {
            started = try await HTTPServer<OutputItem.ID>.start(
                on: serverInterface, acceptingOnly: renderer.address,
                resolve: { shared.file($0) },
                problem: { logger.notice("serving \(name): \($0)") })
        } catch {
            throw .server(error)
        }
        // Closed while it started: nothing may listen past close.
        guard !shared.isClosed else {
            started.stop()
            throw .server(.cancelled)
        }
        server = started
        shared.keep(started)
        return started
    }

    /// Reads once per session whether the renderer has `SetNextAVTransportURI`.
    private func learnGapless() async {
        guard case .unknown = gapless else { return }
        do throws(DescriptionProblem) {
            gapless =
                try await control.actions().contains(AVTransport.setNextURIAction)
                ? .nextURI : .afterStop("its AVTransport has no \(AVTransport.setNextURIAction)")
        } catch {
            gapless = .afterStop("\(error)")
            logger.notice("\(self.renderer.name): \(error)")
        }
    }

    /// Seconds into the loaded track now, as last polled and moved on by the clock since.
    private var elapsed: Double { shared.position(at: now()).map(\.seconds) ?? 0 }

    private func setPosition(_ loaded: Loaded, _ seconds: Double, advancing: Bool) {
        shared.setPosition(
            loaded.item.id, seconds: seconds, at: now(), advancing: advancing,
            durationSeconds: loaded.track.durationSeconds)
    }
}
