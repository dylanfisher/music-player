import Foundation
import Testing

@testable import Playback

private let urls = (0..<2).map { URL(fileURLWithPath: "/music/\($0).flac") }
private let start = Date(timeIntervalSince1970: 1_000_000)

/// Sleeps that return only when the test says, recording how long each asked for.
private actor Sleeps {
    private var waiting: [(seconds: TimeInterval, done: CheckedContinuation<Void, Never>)] = []
    private(set) var asked: [TimeInterval] = []

    func sleep(_ seconds: TimeInterval) async {
        await withCheckedContinuation { continuation in
            asked.append(seconds)
            waiting.append((seconds, continuation))
        }
    }

    /// Ends the oldest sleep still waiting.
    func finishOldest() {
        waiting.removeFirst().done.resume()
    }
}

@MainActor
private final class Harness {
    let sleeps = Sleeps()
    var clock = start
    var recorded: [PlayCounter.Event] = []
    var tracker: PlayTracker!
    var state = PlaybackState()

    init() {
        let sleeps = sleeps
        tracker = PlayTracker(
            playedFraction: 0.5, now: { [unowned self] in self.clock },
            sleep: { seconds in await sleeps.sleep(seconds) },
            record: { [unowned self] in self.recorded += $0 })
        state.queue = urls
    }

    func send(_ event: PlaybackEvent, status: PlaybackState.Status, duration: Double = 100) {
        state.status = status
        state.durationSeconds = duration
        tracker.handle(PlaybackUpdate(state: state, event: event))
    }

    /// Waits until the tracker has asked for `count` sleeps in all.
    func waitForSleeps(_ count: Int) async throws {
        for _ in 0..<1000 {
            if await sleeps.asked.count >= count { return }
            await Task.yield()
        }
        Issue.record("the tracker asked for \(await sleeps.asked.count) sleeps, not \(count)")
    }

    /// Lets the tasks the last step woke run.
    func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }
}

@MainActor @Test func aWakeThatComesEarlySleepsAgainForWhatsLeft() async throws {
    let harness = Harness()
    harness.send(.trackStarted(index: 0), status: .playing)
    try await harness.waitForSleeps(1)
    #expect(await harness.sleeps.asked == [50])

    // The clock stepped: the wake comes a second short.
    harness.clock = start.addingTimeInterval(49)
    await harness.sleeps.finishOldest()
    try await harness.waitForSleeps(2)
    #expect(harness.recorded.isEmpty)
    #expect(await harness.sleeps.asked.last == 1)

    harness.clock = start.addingTimeInterval(50)
    await harness.sleeps.finishOldest()
    await harness.settle()
    #expect(harness.recorded == [.played(urls[0])])
    #expect(await harness.sleeps.asked.count == 2)
}

@MainActor @Test func aPauseCancelsTheWakeAndResumingSchedulesAnother() async throws {
    let harness = Harness()
    harness.send(.trackStarted(index: 0), status: .playing)
    try await harness.waitForSleeps(1)
    harness.clock = start.addingTimeInterval(10)
    harness.send(.paused, status: .paused)

    // The cancelled wake returns late, at what would have been the deadline: nothing counts.
    harness.clock = start.addingTimeInterval(50)
    await harness.sleeps.finishOldest()
    await harness.settle()
    #expect(harness.recorded.isEmpty)
    #expect(await harness.sleeps.asked.count == 1)

    harness.clock = start.addingTimeInterval(1000)
    harness.send(.resumed, status: .playing)
    try await harness.waitForSleeps(2)
    #expect(await harness.sleeps.asked.last == 40)
}

@MainActor @Test func skipsAreRecordedAsTheUpdateComes() async throws {
    let harness = Harness()
    harness.send(.trackStarted(index: 0), status: .playing)
    harness.clock = start.addingTimeInterval(5)
    harness.send(.trackStarted(index: 1), status: .playing)
    #expect(harness.recorded == [.skipped(urls[0])])
}

@MainActor @Test func aWakeOvertakenByAPauseAndResumeDoesNothing() async throws {
    let harness = Harness()
    harness.send(.trackStarted(index: 0), status: .playing)
    try await harness.waitForSleeps(1)
    harness.clock = start.addingTimeInterval(10)
    harness.send(.paused, status: .paused)
    harness.send(.resumed, status: .playing)
    try await harness.waitForSleeps(2)
    // The first wake was cancelled, so its return schedules nothing more.
    await harness.sleeps.finishOldest()
    await harness.settle()
    #expect(await harness.sleeps.asked.count == 2)
}

/// The tracker's own sleeper: a deadline already past wakes at once.
@MainActor @Test func aDeadlineAlreadyPastIsCountedAtOnce() async throws {
    var calls = 0
    var recorded: [PlayCounter.Event] = []
    let tracker = PlayTracker(
        playedFraction: 0.5,
        now: {
            // The second reading, which sets the wait, is past the deadline.
            calls += 1
            return start.addingTimeInterval(calls == 1 ? 0 : 60)
        }, record: { recorded += $0 })
    var state = PlaybackState()
    state.queue = urls
    state.status = .playing
    state.durationSeconds = 100
    tracker.handle(PlaybackUpdate(state: state, event: .trackStarted(index: 0)))
    let deadline = Date().addingTimeInterval(0.5)
    while recorded.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(recorded == [.played(urls[0])])
}
