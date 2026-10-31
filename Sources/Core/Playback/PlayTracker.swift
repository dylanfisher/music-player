import Foundation

/// Feeds a `PlayCounter` the engine's updates and wakes once when the current track would count,
/// so nothing polls. A wake that comes early, as after the clock steps back, sleeps again for
/// what's left; an update that changes the deadline cancels the wait and starts a new one.
@MainActor
public final class PlayTracker {
    /// Waits about this many seconds. Throws when cancelled.
    public typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    private var counter = PlayCounter()
    private var wake: Task<Void, Never>?
    private let now: @MainActor () -> Date
    private let sleep: Sleep
    private let record: @MainActor ([PlayCounter.Event]) -> Void

    /// `record` gets every play and skip as it's counted.
    public init(
        now: @escaping @MainActor () -> Date = Date.init,
        sleep: @escaping Sleep = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1e9))
        },
        record: @escaping @MainActor ([PlayCounter.Event]) -> Void
    ) {
        self.now = now
        self.sleep = sleep
        self.record = record
    }

    public func handle(_ update: PlaybackUpdate) {
        report(counter.handle(update, at: now()))
        schedule()
    }

    private func schedule() {
        wake?.cancel()
        wake = nil
        guard let deadline = counter.deadline else { return }
        let wait = deadline.timeIntervalSince(now())
        let sleep = sleep
        wake = Task { [weak self] in
            do {
                try await sleep(wait)
            } catch {
                // Cancelled: a newer update scheduled its own wake.
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.report(self.counter.tick(at: self.now()))
            self.schedule()
        }
    }

    private func report(_ events: [PlayCounter.Event]) {
        if !events.isEmpty { record(events) }
    }
}
