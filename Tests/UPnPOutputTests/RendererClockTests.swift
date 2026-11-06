import Testing

@testable import UPnPOutput

/// A 60-second track whose clock started at time 0, polled every second from `from` to `to` with
/// the whole-second position `report` gives for each time.
private func polled(
    from: Int = 1, to: Int, _ clock: RendererClock = started(), report: (Double) -> Double
) -> RendererClock {
    var clock = clock
    for time in from...to { clock.polled(report(Double(time)).rounded(.down), at: Double(time)) }
    return clock
}

private func started() -> RendererClock {
    var clock = RendererClock(durationSeconds: 60)
    clock.set(0, at: 0, running: true)
    clock.polled(0, at: 0)
    return clock
}

private let margin = RendererClock.leadMarginSeconds

@Test func aRendererThatLagsByTheSameAmountMovesNothing() {
    // It says 0 for its first five seconds, then five seconds behind to the end.
    let clock = polled(to: 59) { max(0, $0 - 5) }
    #expect(clock.stallSeconds == 0)
    #expect(clock.deadline == 60 + margin)
}

@Test func aStallMovesTheEndByItsLength() {
    // Playing in step for ten seconds, then held at 10 for four.
    let clock = polled(to: 40) { $0 <= 10 ? $0 : max(10, $0 - 4) }
    #expect(clock.stallSeconds == 4)
    #expect(clock.deadline == 64 + margin)
}

@Test func aLongStallMovesTheEndByTheCapAtMost() {
    let clock = polled(to: 59) { min($0, 10) }
    #expect(clock.stallSeconds == RendererClock.stallCapSeconds)
    #expect(clock.deadline == 60 + RendererClock.stallCapSeconds + margin)
}

@Test func aRendererStuckPastTheEndMovesNothing() {
    // Five seconds behind throughout, and stuck where it was at the end.
    let clock = polled(to: 75) { max(0, min($0, 60) - 5) }
    #expect(clock.stallSeconds == 0)
    #expect(clock.isAtEnd(at: 60, slackSeconds: 0))
}

@Test func aStallBeforeThePositionFirstMovesCantBeToldFromALag() {
    let clock = polled(to: 59) { max(0, $0 - 4) }
    #expect(clock.stallSeconds == 0)
}

@Test func theClockPausesAndResumesWithoutThePolledPosition() {
    var clock = polled(to: 20) { max(0, $0 - 5) }
    clock.pause(at: 20.5)
    #expect(clock.deadline == nil)
    #expect(clock.seconds(at: 30) == 20.5)
    clock.resume(at: 30)
    #expect(clock.deadline == 30 + 39.5 + margin)
    #expect(!clock.isAtEnd(at: 30, slackSeconds: 3))
    #expect(clock.isAtEnd(at: 66.5, slackSeconds: 3))
}

@Test func stallsBeforeAndAfterAPauseAddUp() {
    // Three seconds' stall, a pause, then two more; the lag is measured again after the pause.
    var clock = polled(to: 20) { $0 <= 5 ? $0 : max(5, $0 - 3) }
    #expect(clock.stallSeconds == 3)
    clock.pause(at: 20)
    clock.resume(at: 20)
    clock = polled(from: 21, to: 40, clock) { time in
        let played = 17 + (time - 20)
        return time <= 25 ? played : max(17 + 5, played - 2)
    }
    #expect(clock.stallSeconds == 5)
}

@Test func aSeekStartsTheClockAgain() {
    var clock = polled(to: 20) { min($0, 5) }
    #expect(clock.stallSeconds > 0)
    clock.set(30, at: 21, running: true)
    #expect(clock.stallSeconds == 0)
    #expect(clock.deadline == 21 + 30 + margin)
}
