import Foundation

/// Pauses and cancels a running scan from any thread. A paused scan holds no lock on the
/// database, so the library stays readable.
public final class ScanControl: @unchecked Sendable {
    // Every field is guarded by `condition`.
    private let condition = NSCondition()
    private var paused = false
    private var cancelled = false

    public init() {}

    /// The scan stops before its next directory or file until `resume` or `cancel`.
    public func pause() { condition.withLock { paused = true } }

    public func resume() {
        condition.withLock {
            paused = false
            condition.broadcast()
        }
    }

    /// The scan stops at its next directory or file, keeps what it already stored, and removes
    /// nothing, since its walk didn't finish.
    public func cancel() {
        condition.withLock {
            cancelled = true
            condition.broadcast()
        }
    }

    public var isCancelled: Bool { condition.withLock { cancelled } }

    /// Blocks while paused. False once cancelled, when the caller should stop.
    func proceed() -> Bool {
        condition.withLock {
            while paused && !cancelled { condition.wait() }
            return !cancelled
        }
    }
}
