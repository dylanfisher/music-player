import Foundation

/// Where the remote reads and decodes covers (ADR 0215): at most `running` at once, off the
/// actors and the cooperative pool since a file may be on a slow NAS, and at most `waiting`
/// queued behind them; past that a read is refused, so a page or a scanner asking for every
/// cover at once can't queue unbounded work. `pending` is guarded by `lock`.
final class RemoteArtReads: @unchecked Sendable {
    static let runningLimit = 4
    static let waitingLimit = 64

    private let queue = OperationQueue()
    private let lock = NSLock()
    private var pending = 0
    private let capacity: Int

    init(running: Int = runningLimit, waiting: Int = waitingLimit) {
        queue.maxConcurrentOperationCount = running
        queue.qualityOfService = .userInitiated
        capacity = running + waiting
    }

    /// Reads running or waiting, for tests.
    var admitted: Int { lock.withLock { pending } }

    /// `work`'s result once it ran, or a `RemoteBusy` at once when too many are queued.
    func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let admitted = lock.withLock { () -> Bool in
            guard pending < capacity else { return false }
            pending += 1
            return true
        }
        guard admitted else { throw RemoteBusy() }
        return try await withCheckedThrowingContinuation { continuation in
            queue.addOperation { [self] in
                let result = Result { try work() }
                lock.withLock { pending -= 1 }
                continuation.resume(with: result)
            }
        }
    }
}

/// Too many covers are being read already.
struct RemoteBusy: Error, CustomStringConvertible {
    var description: String { "too many covers are being read; ask again" }
}
