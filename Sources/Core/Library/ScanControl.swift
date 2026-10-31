import Foundation

/// Pauses and cancels a running scan from any thread. A paused scan holds no lock on the
/// database, so the library stays readable.
public final class ScanControl: @unchecked Sendable {
    // Every field is guarded by `condition`.
    private let condition = NSCondition()
    private var paused = false
    private var cancelled = false
    private var pauseCount = 0

    public init() {}

    /// The scan stops before its next directory or file until `resume` or `cancel`.
    public func pause() {
        condition.withLock {
            paused = true
            pauseCount += 1
        }
    }

    /// Whether the scan is paused now, and how many times it has paused or resumed, so a
    /// throughput measurement that spans or ends in a pause can be thrown away.
    var pauseState: (isPaused: Bool, changes: Int) {
        condition.withLock { (paused, pauseCount) }
    }

    public func resume() {
        condition.withLock {
            paused = false
            pauseCount += 1
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

    /// Blocks while paused. False once cancelled, when the caller should stop.
    func proceed() -> Bool {
        condition.withLock {
            while paused && !cancelled { condition.wait() }
            return !cancelled
        }
    }
}
