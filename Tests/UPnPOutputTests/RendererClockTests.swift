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

@Test func aRendererWithinAPollsNoiseOfTheClockMovesNothing() {
    let clock = polled(to: 59) { max(0, $0 - 1) }
    #expect(clock.stallSeconds == 0)
    #expect(clock.deadline == 60 + margin)
}

@Test func aFreezeAtTheStartEndsNoEarlierThanTheTracksRealEnd() {
    // It says it plays but holds at 0 for five seconds while it buffers, then plays to the end,
    // which comes at 65.
    let clock = polled(to: 59) { max(0, $0 - 5) }
    #expect(clock.stallSeconds == 5)
    #expect(clock.deadline.map { $0 >= 65 } == true)
    // A stop at its real end still counts as the end.
    #expect(clock.isAtEnd(at: 65, slackSeconds: 0))
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
    // A second behind throughout, and stuck where it was at the end.
    let clock = polled(to: 75) { max(0, min($0, 60) - 1) }
    #expect(clock.stallSeconds == 0)
    #expect(clock.isAtEnd(at: 60, slackSeconds: 0))
}

@Test func theClockPausesAndResumesWithoutThePolledPosition() {
    var clock = polled(to: 20) { $0 }
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

@Test func aPositionFromBeforeASeekBackMovesNothing() {
    var clock = polled(to: 40) { $0 }
    clock.set(10, at: 40, running: true)
    // One poll still reports where it was before the seek, then it reports where it went.
    clock = polled(from: 41, to: 59, clock) { $0 == 41 ? 41 : $0 - 30 }
    #expect(clock.stallSeconds == 0)
}
