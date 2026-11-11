import Foundation
import os

/// The intervals the app marks with signposts, so a Time Profiler or os_signpost trace lines up
/// with the code, and the stall detector can say what ran while the main thread was stuck
/// (ADR 0080). They show in Instruments' Points of Interest.
public enum Interval: CaseIterable, Sendable {
    /// Reading and decoding one cover.
    case artLoad
    /// The track table fetching a page of rows.
    case pageFetch
    /// The browser reloading its lists after the library changed.
    case refresh
    /// A library query that a list on screen waits for.
    case query
    /// Ranking the palette's items for a query.
    case paletteRank
    /// Storing a batch of scanned files.
    case scanBatch
    /// From a play, Next or seek to the first sample of it the device takes.
    case playToFirstSample
    /// At launch: reading the config file and the shortcuts.
    case launchSettings
    /// At launch: opening the index and the state file, and building and showing the window.
    case launchWindow
    /// At launch, once the first rows show: starting playback, scripting and the watcher.
    case launchServices

    /// The signpost's name, which is also how the stall log names the interval.
    var name: StaticString {
        switch self {
        case .artLoad: "art load"
        case .pageFetch: "page fetch"
        case .refresh: "refresh"
        case .query: "query"
        case .paletteRank: "palette rank"
        case .scanBatch: "scan batch"
        case .playToFirstSample: "play to first sample"
        case .launchSettings: "launch settings"
        case .launchWindow: "launch window"
        case .launchServices: "launch services"
        }
    }
}

private let signposter = OSSignposter(subsystem: bundleIdentifier, category: .pointsOfInterest)

/// Runs `body` inside `interval`'s signpost.
public func signposted<T>(_ interval: Interval, _ body: () throws -> T) rethrows -> T {
    let open = OpenInterval(interval)
    defer { open.end() }
    return try body()
}

/// Runs `body` inside `interval`'s signpost, on the caller's actor.
public func signposted<T>(
    _ interval: Interval, isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws -> T
) async rethrows -> T {
    let open = OpenInterval(interval)
    defer { open.end() }
    return try await body()
}

/// An interval begun on one thread and ended on another, at most one open at a time: a play
/// action starts it, and the output's control thread ends it once it sees the device take the
/// first sample, or cancels it when no sound will follow. Safe to use from any thread.
public final class PendingInterval: @unchecked Sendable {
    public static let firstSound = PendingInterval(.playToFirstSample)

    private let interval: Interval
    private let lock = NSLock()
    private var open: (generation: UInt64, interval: OpenInterval)?
    private var began: UInt64 = 0

    public init(_ interval: Interval) { self.interval = interval }

    /// The generation of the latest `begin()`, 0 before the first.
    public var generation: UInt64 { lock.withLock { began } }

    /// Starts the interval, cancelling one still open: a second play before the first's sound
    /// replaces it, and the first made no sound to time. Returns the new interval's generation,
    /// which lets a thread acting on an earlier play leave this one alone.
    @discardableResult
    public func begin() -> UInt64 {
        let (replaced, generation) = lock.withLock {
            let replaced = open
            began += 1
            open = (began, OpenInterval(interval))
            return (replaced, began)
        }
        replaced?.interval.cancel()
        return generation
    }

    /// Ends the interval if it's open.
    public func end() {
        lock.withLock {
            defer { open = nil }
            return open
        }?.interval.end()
    }

    /// Ends the interval if it's open and is `generation`'s.
    public func end(generation: UInt64) {
        lock.withLock { () -> (generation: UInt64, interval: OpenInterval)? in
            guard open?.generation == generation else { return nil }
            defer { open = nil }
            return open
        }?.interval.end()
    }

    /// Closes the interval without recording a time, for a play that makes no sound: stopped,
    /// paused, failed or lost. Does nothing when it isn't open.
    public func cancel() { cancel(upTo: .max) }

    /// Cancels the interval if it's open and began at or before `generation`, so a stop or
    /// failure from before a later play doesn't cancel that play's interval.
    public func cancel(upTo generation: UInt64) {
        lock.withLock { () -> (generation: UInt64, interval: OpenInterval)? in
            guard let current = open, current.generation <= generation else { return nil }
            open = nil
            return current
        }?.interval.cancel()
    }

    public var isOpen: Bool { lock.withLock { open != nil } }
}

/// One interval under way: its signpost, and its entry in `IntervalLog.shared`.
private struct OpenInterval: Sendable {
    let interval: Interval
    let id: UInt64
    let state: OSSignpostIntervalState

    init(_ interval: Interval) {
        self.interval = interval
        id = IntervalLog.shared.begin(interval, at: DispatchTime.now().uptimeNanoseconds)
        state = signposter.beginInterval(interval.name, id: signposter.makeSignpostID())
    }

    func end() {
        signposter.endInterval(interval.name, state)
        IntervalLog.shared.end(id, at: DispatchTime.now().uptimeNanoseconds)
    }

    func cancel() {
        signposter.endInterval(interval.name, state)
        IntervalLog.shared.discard(id)
    }
}

/// An interval's start and end, in uptime nanoseconds; no end while it's still open.
struct IntervalSpan: Equatable, Sendable {
    var interval: Interval
    var start: UInt64
    var end: UInt64?
}

/// The intervals open now and the last few that ended, for the stall detector to name what ran
/// during a stall. Safe to use from any thread.
/// Its intervals are guarded by `lock`.
final class IntervalLog: @unchecked Sendable {
    static let shared = IntervalLog()
    /// Ended intervals kept: enough for a stall's worth of page fetches and queries.
    static let endedKept = 64

    private let lock = NSLock()
    private var nextID: UInt64 = 0
    private var open: [UInt64: IntervalSpan] = [:]
    /// A ring of ended intervals; `oldest` is the next slot to overwrite once full.
    private var ended: [IntervalSpan] = []
    private var oldest = 0

    func begin(_ interval: Interval, at now: UInt64) -> UInt64 {
        lock.withLock {
            nextID += 1
            open[nextID] = IntervalSpan(interval: interval, start: now)
            return nextID
        }
    }

    /// Forgets an open interval without recording that it ended.
    func discard(_ id: UInt64) {
        lock.withLock { _ = open.removeValue(forKey: id) }
    }

    func end(_ id: UInt64, at now: UInt64) {
        lock.withLock {
            guard var span = open.removeValue(forKey: id) else {
                preconditionFailure("interval \(id) ended twice")
            }
            span.end = now
            if ended.count < Self.endedKept {
                ended.append(span)
            } else {
                ended[oldest] = span
                oldest = (oldest + 1) % Self.endedKept
            }
        }
    }

    /// The intervals that were open at some point from `start` to `end`, oldest first.
    func spans(from start: UInt64, to end: UInt64) -> [IntervalSpan] {
        lock.withLock {
            (Array(ended[oldest...]) + ended[..<oldest] + open.values.sorted { $0.start < $1.start })
                .filter { $0.start <= end && ($0.end ?? .max) >= start }
        }
    }
}
