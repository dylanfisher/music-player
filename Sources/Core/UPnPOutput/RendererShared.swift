import Foundation
import LocalNetwork
import Playback

/// What the session shares with the threads that don't run on it: the position `position()`
/// reads, the files the server's `resolve` may hand out, and the server itself, which `close()`
/// stops without waiting on the session. Everything is under one lock.
final class RendererShared: @unchecked Sendable {
    /// How long a token outlives the output's use of it. A renderer buffers ahead and may fetch
    /// the end of a track, or a next track it was given, after the app has moved past it; a
    /// token gone too soon is a dead URL, which a renderer reports as a file it can't decode.
    static let retiredGraceSeconds = 60.0

    private let lock = NSLock()
    private let now: @Sendable () -> Double
    private var served: [OutputItem.ID: (file: HTTPServedFile, retiredAt: Double?)] = [:]
    private var anchor: (item: OutputItem.ID, seconds: Double, at: Double, advancing: Bool)?
    private var duration: Double?
    private var server: HTTPServer<OutputItem.ID>?
    private var pollDue = false
    private var closed = false

    init(now: @escaping @Sendable () -> Double) { self.now = now }

    var isClosed: Bool { lock.withLock { closed } }

    /// Only the items the output holds now, the current and next ones, are served, and those
    /// it let go of for `retiredGraceSeconds` after; any other token, even one the server
    /// issued, is a 404.
    func serve(_ item: OutputItem.ID, _ file: HTTPServedFile) {
        lock.withLock { served[item] = (file, nil) }
    }

    /// The output is done with `item`; its token still serves until the grace runs out.
    func retire(_ item: OutputItem.ID) {
        lock.withLock {
            let time = now()
            if let entry = served[item], entry.retiredAt == nil {
                served[item] = (entry.file, time)
            }
            served = served.filter {
                time - ($0.value.retiredAt ?? time) < Self.retiredGraceSeconds
            }
        }
    }

    func retireAll() {
        let items = lock.withLock { Array(served.keys) }
        for item in items { retire(item) }
    }

    func file(_ item: OutputItem.ID) -> HTTPServedFile? {
        lock.withLock {
            guard let entry = served[item] else { return nil }
            if let retired = entry.retiredAt, now() - retired >= Self.retiredGraceSeconds {
                return nil
            }
            return entry.file
        }
    }

    /// Sets where playback is: `seconds` into `item` at time `at`, moving on with the clock while
    /// `advancing`, up to `durationSeconds`. Nil when nothing is loaded.
    func setPosition(
        _ item: OutputItem.ID?, seconds: Double = 0, at: Double = 0, advancing: Bool = false,
        durationSeconds: Double? = nil
    ) {
        lock.withLock {
            anchor = item.map { ($0, seconds, at, advancing) }
            duration = durationSeconds
        }
    }

    func position(at now: Double) -> OutputPosition? {
        lock.withLock {
            guard let anchor else { return nil }
            var seconds = anchor.seconds + (anchor.advancing ? max(0, now - anchor.at) : 0)
            if let duration { seconds = min(seconds, duration) }
            return OutputPosition(item: anchor.item, seconds: seconds)
        }
    }

    func keep(_ server: HTTPServer<OutputItem.ID>?) { lock.withLock { self.server = server } }

    /// Stops the server and forgets every file, from any thread.
    func stopServer() {
        let server = lock.withLock {
            defer {
                self.server = nil
                served = [:]
            }
            return self.server
        }
        server?.stop()
    }

    private var wantsTicks = false
    private var tickerRunning = false

    /// Says whether the session wants polls; true when a ticker has to be started for it.
    func wantTicks(_ wanted: Bool) -> Bool {
        lock.withLock {
            wantsTicks = wanted && !closed
            guard wantsTicks, !tickerRunning else { return false }
            tickerRunning = true
            return true
        }
    }

    /// Whether the ticker goes on; once nothing wants polls it stops, and says so here.
    func tickerContinues() -> Bool {
        lock.withLock {
            if !wantsTicks { tickerRunning = false }
            return tickerRunning
        }
    }

    var isTicking: Bool { lock.withLock { tickerRunning } }

    /// True once for each poll the ticker asks for, so a slow renderer can't pile them up.
    func claimPoll() -> Bool {
        lock.withLock {
            defer { pollDue = true }
            return !pollDue
        }
    }

    func pollDone() { lock.withLock { pollDue = false } }

    /// Marks the output closed; true the first time only.
    func close() -> Bool {
        lock.withLock {
            defer {
                closed = true
                wantsTicks = false
            }
            return !closed
        }
    }
}
