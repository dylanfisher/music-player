import Foundation
import LocalNetwork
import Log
import Playback
import UPnP

private let logger = moduleLogger()

/// Plays to a UPnP MediaRenderer over AVTransport, sending each file's own bytes from an HTTP
/// server on the interface the renderer is on (ADR 0041). The renderer decodes the file; a
/// format it doesn't list is reported, never transcoded. Every method returns at once: one
/// task runs the commands and the polls in order, off the main thread, each action under a
/// deadline.
public final class RendererOutput: Output, @unchecked Sendable {
    public let events: AsyncStream<OutputEvent>
    /// The signal path whenever it changes; ends when the output closes.
    public let signalPaths: AsyncStream<SignalPath>
    public let renderer: Renderer
    /// The app sends no volume to a renderer: the Denon's is the receiver's own, set over its
    /// control port, and another renderer keeps its own.
    public var hasVolume: Bool { false }

    /// How often the renderer is asked where it is.
    static let pollSeconds = 1.0
    /// Longest an action may take; a slow renderer is still answering well under this.
    static let actionTimeoutSeconds = LocalHTTPClient.timeoutSeconds

    private let shared = RendererShared()
    private let work: AsyncStream<RendererWork>.Continuation
    private let eventContinuation: AsyncStream<OutputEvent>.Continuation
    private let pathContinuation: AsyncStream<SignalPath>.Continuation
    private let control: AVTransportControl
    private let now: @Sendable () -> Double
    private let worker: Task<Void, Never>
    private let ticker: Task<Void, Never>

    /// Throws when the renderer has no AVTransport the app can reach.
    public convenience init(_ renderer: Renderer) throws(RendererOutputError) {
        try self.init(
            renderer: renderer, serverInterface: renderer.location.interface,
            pollSeconds: Self.pollSeconds, timeoutSeconds: Self.actionTimeoutSeconds)
    }

    /// `serverInterface` is where the HTTP server listens: tests pass loopback, since their
    /// made-up interfaces can't be bound.
    init(
        renderer: Renderer, serverInterface: NetworkInterface, pollSeconds: Double,
        timeoutSeconds: Double,
        now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) throws(RendererOutputError) {
        guard let transport = renderer.transport else {
            throw .cannotPlay(
                renderer: renderer.name,
                renderer.transportProblem ?? "discovery found no AVTransport")
        }
        self.renderer = renderer
        self.now = now
        control = AVTransportControl(transport, timeoutSeconds: timeoutSeconds)
        (events, eventContinuation) = AsyncStream.makeStream(of: OutputEvent.self)
        (signalPaths, pathContinuation) = AsyncStream.makeStream(
            of: SignalPath.self, bufferingPolicy: .bufferingNewest(16))
        let (stream, work) = AsyncStream.makeStream(of: RendererWork.self)
        self.work = work
        let session = RendererSession(
            renderer: renderer, control: control, serverInterface: serverInterface,
            shared: shared, emit: { [eventContinuation] in eventContinuation.yield($0) },
            publish: { [pathContinuation] in pathContinuation.yield($0) }, now: now)
        let paths = pathContinuation
        worker = Task {
            paths.yield(await session.signalPath())
            for await item in stream { await session.run(item) }
        }
        let shared = shared
        ticker = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(pollSeconds * 1e9))
                } catch {
                    return
                }
                if shared.claimPoll() { work.yield(.poll) }
            }
        }
    }

    public func load(_ item: OutputItem, startSeconds: Double, playing: Bool) {
        work.yield(.load(item, startSeconds: startSeconds, playing: playing))
    }

    public func setNext(_ item: OutputItem?) { work.yield(.setNext(item)) }
    public func play() { work.yield(.play) }
    public func pause() { work.yield(.pause) }
    public func stop() { work.yield(.stop) }
    public func seek(toSeconds seconds: Double) { work.yield(.seek(seconds)) }

    public func setVolume(_ gain: Double) {
        logger.error("\(self.renderer.name) has no volume the app sets; asked for \(gain)")
    }

    public func position() -> OutputPosition? { shared.position(at: now()) }

    /// Stops listening and ends the streams at once, without waiting on the network: a Stop
    /// goes to the renderer without being awaited, and a renderer still playing stops anyway
    /// when the server it streams from is gone.
    public func close() {
        guard shared.close() else { return }
        let loaded = shared.position(at: now()) != nil
        ticker.cancel()
        worker.cancel()
        work.finish()
        shared.stopServer()
        shared.setPosition(nil)
        eventContinuation.finish()
        pathContinuation.finish()
        guard loaded else { return }
        let control = control
        let name = renderer.name
        Task.detached {
            do throws(SOAPProblem) {
                try await control.send(AVTransport.stop)
            } catch {
                logger.notice("\(name) wasn't stopped on close: \(error)")
            }
        }
    }
}
