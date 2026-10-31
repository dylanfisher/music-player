import Foundation
import Testing

@testable import Library
@testable import Settings

private let local = WatchedFolder(path: "/Users/me/Music", kind: .local)
private let nas = WatchedFolder(path: "/Volumes/Music", kind: .network, pollIntervalMinutes: 15)
private let start = Date(timeIntervalSince1970: 1_000_000)

private func minutes(_ count: Double) -> Date { start.addingTimeInterval(count * 60) }

/// Stands in for the phase 4 engine: reports activity the way it will.
private struct FakeEngine {
    var pausePollingDuringPlayback = false

    func report(_ activity: PlaybackActivity, to state: inout WatchState) {
        state.playbackChanged(activity, pausePollingDuringPlayback: pausePollingDuringPlayback)
    }
}

@Test func scansEveryFolderAtStartLocalFirst() {
    var state = WatchState(folders: [nas, local], pausePollingDuringPlayback: false, now: start)
    #expect(state.start(now: start) == WatchJob(folder: local, subtrees: []))
    #expect(state.start(now: start) == nil, "one scan at a time")
    state.finished(now: start)
    #expect(state.start(now: start) == WatchJob(folder: nas, subtrees: []))
    state.finished(now: minutes(1))
    #expect(state.start(now: minutes(1)) == nil)
}

@Test func pollsNoSoonerThanTheInterval() {
    var state = WatchState(folders: [nas], pausePollingDuringPlayback: false, now: start)
    _ = state.start(now: start)
    state.finished(now: minutes(2))
    #expect(state.nextPoll(after: minutes(2)) == minutes(17))
    #expect(state.start(now: minutes(16.9)) == nil)
    #expect(state.start(now: minutes(17)) == WatchJob(folder: nas, subtrees: []))
    #expect(state.nextPoll(after: minutes(17)) == nil, "nothing to wake for while it runs")
}

@Test func noPollStartsWhilePlaybackIsStarting() {
    var state = WatchState(folders: [nas], pausePollingDuringPlayback: false, now: start)
    let engine = FakeEngine()
    engine.report(.starting, to: &state)
    #expect(state.start(now: start) == nil)
    #expect(state.nextPoll(after: start) == nil, "the engine's next report wakes the watcher")
    engine.report(.playing, to: &state)
    #expect(state.start(now: start) == WatchJob(folder: nas, subtrees: []))

    // A poll already running pauses while the next track starts.
    engine.report(.starting, to: &state)
    #expect(state.holdsRunningScan)
    engine.report(.playing, to: &state)
    #expect(!state.holdsRunningScan)
}

@Test func pollsWaitForPlaybackToStopWhenTheSettingSaysSo() {
    var state = WatchState(folders: [nas], pausePollingDuringPlayback: true, now: start)
    let engine = FakeEngine(pausePollingDuringPlayback: true)
    engine.report(.playing, to: &state)
    #expect(state.start(now: minutes(30)) == nil)
    engine.report(.stopped, to: &state)
    #expect(state.start(now: minutes(30)) == WatchJob(folder: nas, subtrees: []))
    engine.report(.playing, to: &state)
    #expect(state.holdsRunningScan)
}

@Test func playbackNeverHoldsLocalScans() {
    var state = WatchState(folders: [local], pausePollingDuringPlayback: true, now: start)
    FakeEngine(pausePollingDuringPlayback: true).report(.starting, to: &state)
    #expect(state.start(now: start) == WatchJob(folder: local, subtrees: []))
    #expect(!state.holdsRunningScan)
}

@Test func localChangesBecomeSubtreeScans() {
    var state = WatchState(folders: [local, nas], pausePollingDuringPlayback: false, now: start)
    _ = state.start(now: start)
    state.directoriesChanged([
        "/Users/me/Music/B", "/Users/me/Music/A", "/Users/me/Musical/X", "/Volumes/Music/C",
    ])
    state.finished(now: start)
    #expect(
        state.start(now: start)
            == WatchJob(folder: local, subtrees: ["/Users/me/Music/A", "/Users/me/Music/B"]))
    state.finished(now: start)

    state.directoriesChanged(["/Users/me/Music/A"])
    state.folderNeedsWholeScan(containing: "/Users/me/Music/A/B")
    #expect(state.start(now: start) == WatchJob(folder: local, subtrees: []))
}
