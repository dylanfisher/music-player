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

    /// The signpost's name, which is also how the stall log names the interval.
    var name: StaticString {
        switch self {
        case .artLoad: "art load"
        case .pageFetch: "page fetch"
        case .refresh: "refresh"
        case .query: "query"
        case .paletteRank: "palette rank"
        case .scanBatch: "scan batch"
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

/// One interval under way: its signpost, and its entry in `IntervalLog.shared`.
private struct OpenInterval {
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
}

/// An interval's start and end, in uptime nanoseconds; no end while it's still open.
struct IntervalSpan: Equatable, Sendable {
    var interval: Interval
    var start: UInt64
    var end: UInt64?
}

/// The intervals open now and the last few that ended, for the stall detector to name what ran
/// during a stall. Safe to use from any thread.
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
