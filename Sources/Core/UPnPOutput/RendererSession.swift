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
    /// Polls in a row that find it playing or paused other than the engine said before the
    /// engine is told: one alone may be a reply from before the last Play or Pause.
    static let disagreeingPolls = 2
    /// How close to its end a track that stopped must have been to count as played out: the
    /// renderer resets its position when it stops, so the last one polled is all there is.
    static let endSlackSeconds = 3.0
    /// How far before its end a seek lands at most, so a seek to the end doesn't stop it.
    static let seekEndMarginSeconds = 1.0
    /// Ticks between tries of a lost renderer, while waiting for it to answer again.
    static let probeEveryTicks = 5
    /// How long past a track's end, by the app's clock, it waits for the renderer to move on
    /// before it sends the next track itself.
    static let leadMarginSeconds = 2.0
    /// How far behind the app's clock a renderer may report before the clock waits for it:
    /// positions come in whole seconds, and a poll is up to a second old.
    static let behindToleranceSeconds = 1.5

    private final class Loaded {
        let item: OutputItem
        let track: RendererTrack
        let uri: String
        /// What the engine asked for, as opposed to what the renderer says.
        var playing: Bool
        /// The renderer has said it's playing or paused this track, so a stop means it ended.
        var started = false
        /// Play went out and the renderer hasn't yet said it's playing; a Pause given now waits.
        var awaitingPlay = false
        /// A Play or Pause given while `awaitingPlay`, sent once the renderer has started.
        var queuedTransport = false
        var stoppedPolls = 0
        var disagreeingPolls = 0
        /// Where to seek once the renderer has the track playing or paused.
        var pendingSeek: Double?
        /// When the track is over by the app's own clock, from its length in the file, with a
        /// margin; nil while it isn't playing. Past it, the app moves on by itself.
        var deadline: Double?
        /// Polls in a row that found the renderer behind the app's clock.
        var behindPolls = 0
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

    private var renderer: Renderer
    private var control: AVTransportControl
    private let timeoutSeconds: Double
    /// Where the server listens; nil for the interface the renderer was found on.
    private let serverInterfaceOverride: NetworkInterface?
    private let shared: RendererShared
    private let emit: @Sendable (OutputEvent) -> Void
    private let publish: @Sendable (SignalPath) -> Void
    private let now: @Sendable () -> Double
    private let startTicker: @Sendable () -> Void
    private let rediscover: RendererOutput.Rediscover?
    private var server: HTTPServer<OutputItem.ID>?
    private var current: Loaded?
    private var next: Next?
    /// Next tracks the renderer was given and then told otherwise, which it may still play if
    /// the change came too late, as in the last second of a track.
    private var replacedNextURIs: [String] = []
    private var gapless = RendererGapless.unknown
    private var failedPolls = 0
    /// Set from a loss until the renderer answers again, or something else is loaded.
    private var lost = false
    private var ticksSinceProbe = 0

    init(
        renderer: Renderer, control: AVTransportControl, timeoutSeconds: Double,
        serverInterface: NetworkInterface?, shared: RendererShared,
        emit: @escaping @Sendable (OutputEvent) -> Void,
        publish: @escaping @Sendable (SignalPath) -> Void, now: @escaping @Sendable () -> Double,
        startTicker: @escaping @Sendable () -> Void, rediscover: RendererOutput.Rediscover?
    ) {
        self.renderer = renderer
        self.control = control
        self.timeoutSeconds = timeoutSeconds
        serverInterfaceOverride = serverInterface
        self.shared = shared
        self.emit = emit
        self.publish = publish
        self.now = now
        self.startTicker = startTicker
        self.rediscover = rediscover
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
        // Polls run while a track is loaded or a lost renderer is watched for, and the
        // ticker stops otherwise.
        if shared.wantTicks(current != nil || lost) { startTicker() }
    }

    /// The path as it stands, for the panel.
    func signalPath() -> SignalPath {
        SignalPath(
            track: current.map {
                TrackSignal(file: $0.track.signal, decoded: $0.track.signal, isConverted: false)
            },
            sink: .renderer(
                RendererSink(
                    name: renderer.name, address: "\(renderer.address)",
                    contentType: current?.track.contentType, gapless: gapless,
                    volumeIsReceivers: renderer.isDenonReceiver)))
    }

    // MARK: Commands

    private func load(_ item: OutputItem, startSeconds: Double, playing: Bool) async {
        drop()
        if lost { await findAgain() }
        lost = false
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
        loaded.awaitingPlay = playing
        if startSeconds > 0 { loaded.pendingSeek = seekTarget(startSeconds, in: loaded) }
        current = loaded
        setPosition(loaded, startSeconds, advancing: false)
        emit(
            .trackStarted(
                item.id, TrackInfo(durationSeconds: track.durationSeconds, outputFormat: nil)))
        publish(signalPath())
    }

    private func setNext(_ item: OutputItem?) async {
        guard current != nil else { return }
        if let old = next {
            shared.retire(old.item.id)
            if old.sent { replacedNextURIs.append(old.uri) }
        }
        let wasSent = next?.sent == true
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
        if current.awaitingPlay {
            // The Play already sent stands; a Pause queued since is taken back.
            current.playing = true
            current.queuedTransport = false
            return
        }
        guard await send(AVTransport.play) else {
            // Refused: the engine hears it's still paused, rather than a log line alone.
            if self.current === current { emit(.transportChanged(current.item.id, playing: false)) }
            return
        }
        current.playing = true
        current.awaitingPlay = !current.started
        setPosition(current, elapsed, advancing: current.started)
    }

    private func pause() async {
        guard let current, current.playing else { return }
        let seconds = elapsed
        if current.awaitingPlay {
            // A renderer still starting may refuse a Pause, so it waits until it plays.
            current.playing = false
            current.queuedTransport = true
            return setPosition(current, seconds, advancing: false)
        }
        guard await send(AVTransport.pause) else {
            if self.current === current { emit(.transportChanged(current.item.id, playing: true)) }
            return
        }
        current.playing = false
        setPosition(current, seconds, advancing: false)
    }

    private func seek(_ seconds: Double) async {
        guard let current else { return }
        let target = seekTarget(seconds, in: current)
        if current.started {
            guard await send(AVTransport.seek(toSeconds: target)) else {
                if self.current === current {
                    emit(.seekFailed(current.item.id, positionSeconds: elapsed))
                }
                return
            }
        } else {
            current.pendingSeek = target
        }
        setPosition(current, target, advancing: current.playing && current.started)
    }

    /// `seconds` within the track, short of its very end.
    private func seekTarget(_ seconds: Double, in loaded: Loaded) -> Double {
        min(max(0, seconds), max(0, loaded.track.durationSeconds - Self.seekEndMarginSeconds))
    }

    /// A renderer that doesn't answer a Stop isn't reported lost: nothing is playing to lose.
    private func stop() async {
        lost = false
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
        guard let current else { return await probe() }
        // The app leads: past the track's end by its own clock, the next track goes out
        // whatever the renderer says, or would say if it answered.
        if current.playing, let deadline = current.deadline, now() >= deadline {
            return await lead(past: current)
        }
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
        if !position.trackURI.isEmpty, !sameURI(position.trackURI, current.uri) {
            if let next, next.sent, sameURI(position.trackURI, next.uri) {
                return advance(from: current, to: next, gapless: true)
            }
            if replacedNextURIs.contains(where: { sameURI($0, position.trackURI) }) {
                return await resync(current)
            }
            emit(
                .failed(
                    current.item.id,
                    RendererOutputError.playingSomethingElse(renderer: renderer.name)))
            return release()
        }
        switch transport.state {
        case .playing, .paused:
            await playingOrPaused(current, playing: transport.state == .playing, position)
            if !transport.isOK {
                logger.notice("\(self.renderer.name) reports an error while playing")
            }
        case .stopped, .noMedia:
            await stopped(current, transportOK: transport.isOK)
        case .transitioning, .other:
            break
        }
    }

    /// The renderer has the track: what waited for that goes out, and a renderer that plays
    /// or pauses other than the engine said, from its own remote or a refused command, is
    /// followed, and the engine told.
    private func playingOrPaused(_ current: Loaded, playing: Bool, _ position: PositionInfo)
        async
    {
        let firstSeen = !current.started
        current.started = true
        current.awaitingPlay = false
        current.stoppedPolls = 0
        if let duration = position.durationSeconds, duration > 0 {
            current.durationSeconds = duration
        }
        var rendererPlaying = playing
        if current.queuedTransport {
            current.queuedTransport = false
            if playing != current.playing {
                let action = current.playing ? AVTransport.play : AVTransport.pause
                if await send(action) { rendererPlaying = current.playing }
                guard self.current === current else { return }
            }
        }
        if let target = current.pendingSeek {
            current.pendingSeek = nil
            guard await send(AVTransport.seek(toSeconds: target)) else {
                guard self.current === current else { return }
                emit(.seekFailed(current.item.id, positionSeconds: position.seconds ?? 0))
                return setPosition(current, position.seconds ?? 0, advancing: rendererPlaying)
            }
            setPosition(current, target, advancing: rendererPlaying)
        } else if rendererPlaying, let seconds = position.seconds {
            // The renderer's own position starts the app's clock for the track, once; after
            // that it only corrects what's shown, and holds the end back for a renderer that
            // fell behind, as one re-buffering does.
            let resets = firstSeen || current.deadline == nil
            let deadline = current.deadline
            setPosition(current, seconds, advancing: true, resetsDeadline: resets)
            if !resets, let deadline { holdBack(current, deadline, polledSeconds: seconds) }
        }
        // Paused, the position can change only by the app's own seek, which set it; some
        // renderers report the position from before that seek until they play again.
        guard rendererPlaying != current.playing else {
            current.disagreeingPolls = 0
            return
        }
        current.disagreeingPolls += 1
        guard current.disagreeingPolls >= Self.disagreeingPolls else { return }
        current.disagreeingPolls = 0
        current.playing = rendererPlaying
        if !rendererPlaying { setPosition(current, position.seconds ?? elapsed, advancing: false) }
        emit(.transportChanged(current.item.id, playing: rendererPlaying))
    }

    /// Moves the track's end later when the renderer is behind the app's clock by more than
    /// `behindToleranceSeconds` two polls running, short of the track's last seconds: it
    /// stalled, and the clock would otherwise cut those seconds off. A poll never moves the end
    /// earlier.
    private func holdBack(_ current: Loaded, _ deadline: Double, polledSeconds: Double) {
        let time = now()
        let clockSeconds =
            current.track.durationSeconds - (deadline - Self.leadMarginSeconds - time)
        // In the last seconds a renderer that's behind is stuck at the end, not re-buffering,
        // and waiting on it would never end the track.
        guard clockSeconds - polledSeconds > Self.behindToleranceSeconds,
            polledSeconds < current.track.durationSeconds - Self.endSlackSeconds
        else {
            current.behindPolls = 0
            current.deadline = deadline
            return
        }
        current.behindPolls += 1
        let later =
            time + max(0, current.track.durationSeconds - polledSeconds) + Self.leadMarginSeconds
        current.deadline =
            current.behindPolls >= Self.disagreeingPolls ? max(deadline, later) : deadline
    }

    /// The track should have ended and the renderer hasn't moved on: the app sends the next
    /// track itself, or stops it when nothing is next.
    private func lead(past current: Loaded) async {
        logger.notice("\(self.renderer.name) hadn't moved on by the track's end; the app does")
        guard next != nil else {
            await send(AVTransport.stop)
            guard self.current === current else { return }
            emit(.trackEnded(current.item.id))
            emit(.finished(current.item.id))
            return release()
        }
        await ended(current)
    }

    /// The renderer is on a next track it was told to drop: the change came too late. The
    /// current track counts as ended, and what the engine has next replaces it.
    private func resync(_ current: Loaded) async {
        logger.notice("\(self.renderer.name) went on to a next track it was told to drop")
        guard next != nil else {
            await send(AVTransport.stop)
            emit(.trackEnded(current.item.id))
            emit(.finished(current.item.id))
            return release()
        }
        await ended(current)
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
        // Given the next track, a renderer that stops at the end may be on its way to it; the
        // app's own clock decides when it has waited long enough.
        guard next?.sent != true else { return }
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
        shared.retire(current.item.id)
        let loaded = Loaded(next.item, next.track, uri: next.uri, playing: true)
        loaded.started = gapless
        loaded.awaitingPlay = !gapless
        self.current = loaded
        self.next = nil
        replacedNextURIs = []
        setPosition(loaded, 0, advancing: gapless)
        emit(
            .trackStarted(
                next.item.id,
                TrackInfo(durationSeconds: next.track.durationSeconds, outputFormat: nil)))
        publish(signalPath())
    }

    // MARK: Losing, finding again and releasing

    /// An action on `item` failed: the renderer is gone if it didn't answer, otherwise it
    /// refused the track.
    private func fail(_ item: OutputItem, _ error: SOAPProblem, at seconds: Double, finishing: Bool)
    {
        if case .unreachable = error {
            emit(.deviceLost(item.id, positionSeconds: seconds))
            release()
            lost = true
            return
        }
        emit(
            .trackFailed(
                item.id, RendererOutputError.refused(renderer: renderer.name, "\(error)")))
        if finishing { emit(.finished(item.id)) }
        release()
    }

    private func lose(_ current: Loaded, _ error: SOAPProblem) {
        logger.error("\(self.renderer.name) is gone: \(error)")
        emit(.deviceLost(current.item.id, positionSeconds: elapsed))
        release()
        lost = true
    }

    /// Asks a lost renderer where it is every few ticks; the first answer says it's back.
    private func probe() async {
        guard lost else { return }
        ticksSinceProbe += 1
        guard ticksSinceProbe >= Self.probeEveryTicks else { return }
        ticksSinceProbe = 0
        do throws(SOAPProblem) {
            _ = try await control.transportInfo()
        } catch {
            return
        }
        guard lost, current == nil else { return }
        lost = false
        logger.notice("\(self.renderer.name) answers again")
        emit(.deviceReturned)
    }

    /// Searches for the renderer by its UDN after a loss, since a renderer that left and came
    /// back may have a new address from DHCP; one found elsewhere is played to there.
    private func findAgain() async {
        guard let rediscover else { return }
        let found: Renderer
        do {
            found = try RendererChoice.renderer(renderer.udn, in: try await rediscover())
        } catch {
            return logger.notice("\(self.renderer.name) wasn't found again: \(error)")
        }
        guard found.location != renderer.location, let transport = found.transport else { return }
        logger.notice("\(found.name) is at \(found.address) now")
        renderer = found
        control = AVTransportControl(transport, timeoutSeconds: timeoutSeconds)
        gapless = .unknown
        server = nil
        shared.stopServer()
    }

    /// Forgets what's loaded but keeps the server, for a load that replaces it.
    private func drop() {
        current = nil
        next = nil
        replacedNextURIs = []
        failedPolls = 0
        shared.retireAll()
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
                on: serverInterfaceOverride ?? renderer.location.interface,
                acceptingOnly: renderer.address, resolve: { shared.file($0) },
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

    /// Sets where playback is. A position the app set itself, by a start, seek, play or pause,
    /// also sets when the track should be over by its own clock; one a poll reports leaves
    /// that alone, so a renderer that stalls near the end can't keep moving it.
    private func setPosition(
        _ loaded: Loaded, _ seconds: Double, advancing: Bool, resetsDeadline: Bool = true
    ) {
        let time = now()
        shared.setPosition(
            loaded.item.id, seconds: seconds, at: time, advancing: advancing,
            durationSeconds: loaded.track.durationSeconds)
        guard resetsDeadline else { return }
        loaded.deadline =
            advancing
            ? time + max(0, loaded.track.durationSeconds - seconds) + Self.leadMarginSeconds
            : nil
    }
}

/// Whether two URIs name the same stream once a renderer's rewriting is undone: the scheme and
/// host in any case, port 80 when none is given (the app serves only http), percent-encoding
/// decoded.
func sameURI(_ a: String, _ b: String) -> Bool {
    guard a != b else { return true }
    guard let left = URLComponents(string: a), let right = URLComponents(string: b) else {
        return false
    }
    func key(_ parts: URLComponents) -> [String?] {
        [
            parts.scheme?.lowercased(), parts.host?.lowercased(),
            String(parts.port ?? 80),
            parts.path, parts.query,
        ]
    }
    return key(left) == key(right)
}
