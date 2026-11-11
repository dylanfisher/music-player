import Foundation

/// What a test replaces around `DeviceOutput`'s control thread, so it can run the thread's passes
/// itself, one `step()` at a time, against a count of bytes consumed and a clock it sets. The
/// defaults are production's: a thread of its own, the IO proc's count and the system uptime.
/// Nothing the IO proc reaches changes.
struct ControlSeam {
    /// False leaves the thread unstarted: the test calls `step()`, and `close()` runs the
    /// closing pass itself.
    var startThread = true
    /// Read in place of the IO proc's count of bytes consumed.
    var consumed: (() -> UInt64)?
    /// The clock a drain and a pause's fade-out are waited out on.
    var now: () -> Double = uptime
    /// Called in a refill after each chunk is written, before its boundaries are announced and
    /// its position is published, where the IO proc can move on while a refill reads a NAS.
    var afterChunk: (() -> Void)?
}

extension DeviceOutput {
    /// The control thread: a pass each time a command is posted or a tick is due, until one
    /// closes the output.
    func run() {
        while true {
            wait()
            guard step() else { return }
        }
    }

    /// Sleeps until a command is posted or, while playing or decoding ahead, the next tick.
    private func wait() {
        condition.lock()
        defer { condition.unlock() }
        guard pending.isEmpty else { return }
        if let interval = tickSeconds {
            _ = condition.wait(until: Date(timeIntervalSinceNow: interval))
        } else {
            condition.wait()
        }
    }

    /// One pass: every command posted so far, in order, then the refill, the boundaries, the
    /// drain and the position, a return to a device that came back, and the signal path. False
    /// once a command closed the output.
    @discardableResult
    func step() -> Bool {
        let batch = condition.withLock {
            defer { pending = [] }
            return pending
        }
        for (command, generation) in batch {
            passGeneration = generation
            perform(command)
            if case .close = command { return false }
        }
        passGeneration = firstSound.generation
        service()
        if returnDue {
            returnDue = false
            checkReturn()
        }
        publishSignal()
        return true
    }
}
