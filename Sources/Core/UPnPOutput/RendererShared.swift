import Foundation
import LocalNetwork
import Playback

/// What the session shares with the threads that don't run on it: the position `position()`
/// reads, the files the server's `resolve` may hand out, and the server itself, which `close()`
/// stops without waiting on the session. Everything is under one lock.
final class RendererShared: @unchecked Sendable {
    private let lock = NSLock()
    private var served: [OutputItem.ID: HTTPServedFile] = [:]
    private var anchor: (item: OutputItem.ID, seconds: Double, at: Double, advancing: Bool)?
    private var duration: Double?
    private var server: HTTPServer<OutputItem.ID>?
    private var pollDue = false
    private var closed = false

    var isClosed: Bool { lock.withLock { closed } }

    /// Only the items the output holds now, the current and next ones, are served; any other
    /// token, even one the server issued, is a 404.
    func serve(_ item: OutputItem.ID, _ file: HTTPServedFile) {
        lock.withLock { served[item] = file }
    }

    func unserve(_ item: OutputItem.ID) { _ = lock.withLock { served.removeValue(forKey: item) } }

    func unserveAll() { lock.withLock { served = [:] } }

    func file(_ item: OutputItem.ID) -> HTTPServedFile? { lock.withLock { served[item] } }

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
            defer { closed = true }
            return !closed
        }
    }
}
