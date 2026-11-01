/// A hybrid logical clock (ADR 0038): wall time in milliseconds since 1970, and a counter for
/// events in the same millisecond or after a later clock than the wall's.
struct SyncClock: Comparable, Hashable, Sendable {
    var ms: Int64
    var counter: Int64

    /// How far a field's clock can move this machine's own clock past its wall time.
    static let skewBoundMs: Int64 = 3_600_000
    /// What a log may hold: up to 2100 for the time, and a counter no edit chain reaches.
    static let msRange: ClosedRange<Int64> = 0...4_102_444_800_000
    static let counterRange: ClosedRange<Int64> = 0...Int64(Int32.max)

    static func < (a: SyncClock, b: SyncClock) -> Bool {
        (a.ms, a.counter) < (b.ms, b.counter)
    }

    /// The clock after this one; the counter past its range starts a new millisecond.
    var successor: SyncClock {
        counter < Self.counterRange.upperBound
            ? SyncClock(ms: ms, counter: counter + 1) : SyncClock(ms: ms + 1, counter: 0)
    }

    /// The clock of a new event from a machine whose clock is `last`, at `wallMs`, and that
    /// machine's clock after it. With `field`, the clock of the change the edited field holds,
    /// the event comes after that too, but the machine's clock moves at most
    /// `skewBoundMs` past its wall time, so one far-off clock can't carry it along.
    static func next(after last: SyncClock, wallMs: Int64, field: SyncClock? = nil) -> (
        event: SyncClock, state: SyncClock
    ) {
        var event = last.ms >= wallMs ? last.successor : SyncClock(ms: wallMs, counter: 0)
        if let field, field >= event { event = field.successor }
        let bound = SyncClock(ms: wallMs + skewBoundMs, counter: 0)
        return (event, event <= bound ? event : max(last, bound))
    }
}

/// When a change was made and on which machine: what last writer wins compares, the clock
/// first and the machine ID on a tie, so every machine picks the same winner.
struct SyncStamp: Comparable, Hashable, Sendable {
    var clock: SyncClock
    var machine: String

    static func < (a: SyncStamp, b: SyncStamp) -> Bool {
        (a.clock, a.machine) < (b.clock, b.machine)
    }
}
