import Library
import Playback
import Testing

@testable import MusicPlayer

@Test func aTrackStartingHoldsPollsBackAndPausedCountsAsStopped() {
    var state = PlaybackState()
    #expect(watcherActivity(state) == .stopped)
    state.status = .playing
    #expect(watcherActivity(state) == .starting)
    state.durationSeconds = 200
    #expect(watcherActivity(state) == .playing)
    state.status = .paused
    #expect(watcherActivity(state) == .stopped)
}
