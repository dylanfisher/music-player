import Foundation
import IOKit.pwr_mgt
import Log

private let logger = moduleLogger()

/// Keeps the Mac from idle sleep while a renderer plays. A renderer pulls the stream from the
/// app's HTTP server, so no CoreAudio IO holds the assertion it holds for a local device
/// (ADR 0197). At most one is held; the session says what it wants after each command and
/// poll, and `close()` lets go from any thread without waiting on the session.
final class SleepAssertion: @unchecked Sendable {
    private let lock = NSLock()
    private let calls: SleepAssertionCalls
    private let name: String
    private var wanted = false
    private var held: IOPMAssertionID?
    private var closed = false

    init(name: String, calls: SleepAssertionCalls) {
        self.name = name
        self.calls = calls
    }

    /// Takes the assertion when `wanted` turns true and releases it when it turns false. A
    /// create that fails is logged and not tried again until the next time it turns true, so
    /// a poll each second doesn't log each second.
    func hold(_ wanted: Bool) {
        lock.withLock {
            let wanted = wanted && !closed
            guard wanted != self.wanted else { return }
            self.wanted = wanted
            if wanted { take() } else { releaseHeld() }
        }
    }

    /// Releases the assertion, and no hold after this takes one: a command the session was
    /// running as the output closed may still finish.
    func close() {
        lock.withLock {
            closed = true
            wanted = false
            releaseHeld()
        }
    }

    private func take() {
        switch calls.create(name) {
        case .success(let id): held = id
        case .failure(let failure):
            logger.error(
                "couldn't keep the Mac awake for \(self.name, privacy: .public): \(failure, privacy: .public)"
            )
        }
    }

    private func releaseHeld() {
        guard let id = held else { return }
        held = nil
        let result = calls.release(id)
        guard result != kIOReturnSuccess else { return }
        logger.error(
            "couldn't release \(self.name, privacy: .public)'s sleep assertion: \(SleepAssertionFailure(code: result), privacy: .public)"
        )
    }
}
