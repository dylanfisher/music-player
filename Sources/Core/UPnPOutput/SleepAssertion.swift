import Foundation
import IOKit.pwr_mgt
import Log

private let logger = moduleLogger()

/// Keeps the Mac from idle sleep while a renderer plays. A renderer pulls the stream from the
/// app's HTTP server, so no CoreAudio IO holds the assertion it holds for a local device
/// (ADR 0197). At most one is held; the session says what it wants after each command and
/// poll, one at a time, and `close()` lets go from any thread. The lock guards only the state:
/// the IOKit calls, a round trip to powerd, run outside it, so `close()` never waits on a create
/// the session has under way.
final class SleepAssertion: @unchecked Sendable {
    private let lock = NSLock()
    private let calls: SleepAssertionCalls
    /// What the last assertion taken was named, for the log.
    private var name = ""
    private var wanted = false
    private var held: IOPMAssertionID?
    private var closed = false

    init(calls: SleepAssertionCalls) {
        self.calls = calls
    }

    /// An output dropped without `close()` still lets go.
    deinit {
        if let held { release(held) }
    }

    /// Takes the assertion, named `name`, when `wanted` turns true and releases it when it turns
    /// false. The name is the session's, given each time, since the renderer it plays to may
    /// change when it's found again at a new address. A
    /// create that fails is logged and not tried again until the next time it turns true, so
    /// a poll each second doesn't log each second. Called by one caller at a time, the session.
    func hold(_ wanted: Bool, as name: String) {
        let (taking, releasing) = lock.withLock { () -> (Bool, IOPMAssertionID?) in
            let wanted = wanted && !closed
            guard wanted != self.wanted else { return (false, nil) }
            self.wanted = wanted
            defer { if !wanted { held = nil } }
            return (wanted, wanted ? nil : held)
        }
        if let releasing { release(releasing) }
        if taking { take(name) }
    }

    /// Releases the assertion, and no hold after this takes one: a command the session was
    /// running as the output closed may still finish, and a create under way as it closed is
    /// released as it returns.
    func close() {
        let releasing = lock.withLock { () -> IOPMAssertionID? in
            closed = true
            wanted = false
            defer { held = nil }
            return held
        }
        if let releasing { release(releasing) }
    }

    private func take(_ name: String) {
        lock.withLock { self.name = name }
        switch calls.create(name) {
        case .success(let id):
            // Closed, or let go, while the create ran: this one is released at once.
            let kept = lock.withLock { () -> Bool in
                guard wanted, !closed else { return false }
                held = id
                return true
            }
            if !kept { release(id) }
        case .failure(let failure):
            logger.error(
                "couldn't keep the Mac awake for \(name, privacy: .public): \(failure, privacy: .public)"
            )
        }
    }

    private func release(_ id: IOPMAssertionID) {
        let result = calls.release(id)
        guard result != kIOReturnSuccess else { return }
        let name = lock.withLock { self.name }
        logger.error(
            "couldn't release \(name, privacy: .public)'s sleep assertion: \(SleepAssertionFailure(code: result), privacy: .public)"
        )
    }
}
