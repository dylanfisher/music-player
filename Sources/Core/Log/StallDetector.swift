import Foundation

private let logger = moduleLogger()

/// Logs each time the main thread stays busy over `thresholdNanos` without waiting for input:
/// how long, the intervals that ran meanwhile, the last command run and the event being handled
/// (ADR 0080). It can't sample the main thread's stack cheaply, so those place the stall
/// instead. Run-loop observers note every change of the loop's activity, and only the time from
/// going to sleep to waking is idle; there is no timer, so an idle app pays nothing. A main
/// thread that never comes back is never logged.
@MainActor
public final class StallDetector {
    /// About six frames: a hitch the user sees, not one a busy frame makes.
    static let thresholdNanos: UInt64 = 100_000_000

    private var clock = StallClock(thresholdNanos: thresholdNanos)
    /// Removed when the detector goes, which only tests' detectors do.
    nonisolated(unsafe) private var observer: CFRunLoopObserver?
    private var lastCommand: String?
    private let event: () -> String?
    private let report: (Stall) -> Void

    /// `event` names the event the app is handling, if any.
    public convenience init(event: @escaping () -> String?) {
        self.init(event: event) { logger.notice("\($0.description, privacy: .public)") }
    }

    init(event: @escaping () -> String?, report: @escaping (Stall) -> Void) {
        self.event = event
        self.report = report
    }

    /// Starts watching the main run loop in every common mode.
    public func start() {
        precondition(observer == nil, "the stall detector is already watching")
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.allActivities.rawValue, true, 0
        ) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.mark(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    deinit {
        if let observer { CFRunLoopObserverInvalidate(observer) }
    }

    /// Notes the command about to run, which a stall's log names.
    public func noteCommand(_ name: String) { lastCommand = name }

    private func mark(_ activity: CFRunLoopActivity) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard let (start, end) = clock.mark(asleep: activity == .beforeWaiting, at: now) else {
            return
        }
        report(
            Stall(
                milliseconds: Double(end - start) / 1e6,
                intervals: IntervalLog.shared.spans(from: start, to: end).map { span in
                    (span.interval, Double((span.end ?? end) - max(span.start, start)) / 1e6)
                }, lastCommand: lastCommand, event: event()))
    }
}

/// The time between the main run loop's marks. Busy from any mark to the next, except from
/// going to sleep to waking.
struct StallClock {
    let thresholdNanos: UInt64
    private var lastMark: UInt64?
    private var asleep = false

    init(thresholdNanos: UInt64) { self.thresholdNanos = thresholdNanos }

    /// Notes a mark at `now`, `asleep` when the loop is about to wait. Returns the stall it ends,
    /// from the last mark to `now`, when the loop was busy that long.
    mutating func mark(asleep: Bool, at now: UInt64) -> (UInt64, UInt64)? {
        defer {
            lastMark = now
            self.asleep = asleep
        }
        guard !self.asleep, let lastMark, now - lastMark > thresholdNanos else { return nil }
        return (lastMark, now)
    }
}

/// One stall of the main thread, as logged.
struct Stall: CustomStringConvertible {
    var milliseconds: Double
    /// Each interval that ran during the stall, with the time it overlapped it.
    var intervals: [(Interval, Double)]
    var lastCommand: String?
    var event: String?

    var description: String {
        var parts = [
            String(format: "main thread stalled %.0f ms", milliseconds),
            "ran: "
                + (intervals.isEmpty
                    ? "no marked interval"
                    : intervals.map { "\($0.0.name) \(String(format: "%.0f", $0.1)) ms" }
                        .joined(separator: ", ")),
        ]
        if let lastCommand { parts.append("last command: \(lastCommand)") }
        if let event { parts.append("event: \(event)") }
        return parts.joined(separator: "; ")
    }
}
