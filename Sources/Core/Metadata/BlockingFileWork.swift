import Foundation

/// Runs `work`, which may wait on a slow or hung volume, on a global queue, and returns its
/// result to the caller's actor. A share that stops answering holds one dispatch thread, never
/// the main thread or one of the cooperative pool's few threads (ADR 0081).
public func blockingFileWork<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
    }
}

/// Runs `work` on a global queue and waits for it at most `seconds`, for the few places the main
/// thread must wait, as at quit. False when it hadn't finished; it then runs on unwaited.
public func finishes(within seconds: Double, _ work: @escaping @Sendable () -> Void) -> Bool {
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        work()
        done.signal()
    }
    return done.wait(timeout: .now() + seconds) == .success
}
