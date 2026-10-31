import Foundation
import Testing

@testable import Playback

private let urls = (0..<3).map { URL(fileURLWithPath: "/music/\($0).flac") }
private let start = Date(timeIntervalSince1970: 1_000_000)

/// Feeds a counter updates as the engine would send them, at seconds after `start`.
private struct Feed {
    var counter = PlayCounter()
    var state = PlaybackState()

    init(durations: [Double]) {
        state.queue = urls
        self.durations = durations
    }

    let durations: [Double]

    mutating func send(_ event: PlaybackEvent, status: PlaybackState.Status, at seconds: Double)
        -> [PlayCounter.Event]
    {
        state.status = status
        if case .trackStarted(let index) = event { state.durationSeconds = durations[index] }
        return counter.handle(
            PlaybackUpdate(state: state, event: event), at: start.addingTimeInterval(seconds))
    }

    mutating func tick(at seconds: Double) -> [PlayCounter.Event] {
        counter.tick(at: start.addingTimeInterval(seconds))
    }
}

@Test func aShortTrackCountsAtHalfItsLength() {
    var feed = Feed(durations: [100, 600, 100])
    #expect(feed.send(.trackStarted(index: 0), status: .playing, at: 0).isEmpty)
    #expect(feed.counter.deadline == start.addingTimeInterval(50))
    #expect(feed.tick(at: 49).isEmpty)
    #expect(feed.tick(at: 50) == [.played(urls[0])])
    #expect(feed.counter.deadline == nil)
    #expect(feed.tick(at: 90).isEmpty)
}

@Test func aLongTrackCountsAtFourMinutes() {
    var feed = Feed(durations: [100, 600, 100])
    _ = feed.send(.trackStarted(index: 1), status: .playing, at: 0)
    #expect(feed.counter.deadline == start.addingTimeInterval(PlayCounter.playSeconds))
    #expect(feed.tick(at: PlayCounter.playSeconds) == [.played(urls[1])])
}

@Test func pausedTimeDoesntCount() {
    var feed = Feed(durations: [100, 600, 100])
    _ = feed.send(.trackStarted(index: 0), status: .playing, at: 0)
    #expect(feed.send(.paused, status: .paused, at: 30).isEmpty)
    #expect(feed.counter.deadline == nil)
    #expect(feed.tick(at: 500).isEmpty)
    _ = feed.send(.resumed, status: .playing, at: 1000)
    #expect(feed.counter.deadline == start.addingTimeInterval(1020))
    #expect(feed.tick(at: 1019).isEmpty)
    #expect(feed.tick(at: 1020) == [.played(urls[0])])
}

@Test func movingOnBeforeAPlayIsASkip() {
    var feed = Feed(durations: [100, 600, 100])
    _ = feed.send(.trackStarted(index: 0), status: .playing, at: 0)
    #expect(feed.send(.trackStarted(index: 1), status: .playing, at: 10) == [.skipped(urls[0])])
    // A track that counted isn't skipped when the next starts.
    #expect(feed.tick(at: 10 + PlayCounter.playSeconds) == [.played(urls[1])])
    #expect(feed.send(.trackStarted(index: 2), status: .playing, at: 300).isEmpty)
}

@Test func aTrackThatPlayedToItsEndIsntASkip() {
    // Seeking ahead means the end comes before half the track was heard.
    var feed = Feed(durations: [100, 600, 100])
    _ = feed.send(.trackStarted(index: 0), status: .playing, at: 0)
    _ = feed.send(.trackEnded(index: 0), status: .playing, at: 20)
    #expect(feed.send(.trackStarted(index: 2), status: .playing, at: 20).isEmpty)
}

@Test func aLateUpdateCountsThePlayBeforeTheNextTrack() {
    // No tick came, as when the app was busy: the next update still counts the play first.
    var feed = Feed(durations: [100, 600, 100])
    _ = feed.send(.trackStarted(index: 0), status: .playing, at: 0)
    #expect(feed.send(.trackStarted(index: 2), status: .playing, at: 70) == [.played(urls[0])])
}

@Test func repeatingATrackCountsEachPlay() {
    var feed = Feed(durations: [100, 600, 100])
    _ = feed.send(.trackStarted(index: 0), status: .playing, at: 0)
    #expect(feed.tick(at: 50) == [.played(urls[0])])
    _ = feed.send(.trackEnded(index: 0), status: .playing, at: 100)
    #expect(feed.send(.trackStarted(index: 0), status: .playing, at: 100).isEmpty)
    #expect(feed.tick(at: 150) == [.played(urls[0])])
}

@Test func aTrackWithNoKnownLengthCountsAtFourMinutes() {
    var feed = Feed(durations: [0, 600, 100])
    _ = feed.send(.trackStarted(index: 0), status: .playing, at: 0)
    #expect(feed.counter.deadline == start.addingTimeInterval(PlayCounter.playSeconds))
}
