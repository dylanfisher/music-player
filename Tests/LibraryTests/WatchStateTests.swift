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
    var state = WatchState(
        folders: [nas, local], indexed: [], rescanNetworkFoldersAtLaunch: false,
        pausePollingDuringPlayback: false, now: start)
    #expect(state.start(now: start) == WatchJob(folder: local, subtrees: []))
    #expect(state.start(now: start) == nil, "one scan at a time")
    state.finished(now: start)
    #expect(state.start(now: start) == WatchJob(folder: nas, subtrees: []))
    state.finished(now: minutes(1))
    #expect(state.start(now: minutes(1)) == nil)
}

@Test func aNetworkFolderTheIndexHoldsWaitsAnIntervalForItsFirstPoll() {
    let added = WatchedFolder(path: "/Volumes/Added", kind: .network)
    var state = WatchState(
        folders: [nas, added, local], indexed: [nas.path], rescanNetworkFoldersAtLaunch: false,
        pausePollingDuringPlayback: false, now: start)
    #expect(state.leftToTheIndex == [nas.path])
    #expect(state.start(now: start) == WatchJob(folder: local, subtrees: []))
    state.finished(now: start)
    // A folder the index holds nothing for is scanned at once.
    #expect(state.start(now: start) == WatchJob(folder: added, subtrees: []))
    state.finished(now: minutes(1))
    #expect(state.start(now: minutes(1)) == nil)
    #expect(state.nextPoll(after: minutes(1)) == minutes(15))
    #expect(state.start(now: minutes(15)) == WatchJob(folder: nas, subtrees: []))
}

@Test func theSettingBringsBackTheLaunchRescan() {
    var state = WatchState(
        folders: [nas], indexed: [nas.path], rescanNetworkFoldersAtLaunch: true,
        pausePollingDuringPlayback: false, now: start)
    #expect(state.leftToTheIndex.isEmpty)
    #expect(state.start(now: start) == WatchJob(folder: nas, subtrees: []))
}

@Test func pollsNoSoonerThanTheInterval() {
    var state = WatchState(
        folders: [nas], indexed: [], rescanNetworkFoldersAtLaunch: false,
        pausePollingDuringPlayback: false, now: start)
    _ = state.start(now: start)
    state.finished(now: minutes(2))
    #expect(state.nextPoll(after: minutes(2)) == minutes(17))
    #expect(state.start(now: minutes(16.9)) == nil)
    #expect(state.start(now: minutes(17)) == WatchJob(folder: nas, subtrees: []))
    #expect(state.nextPoll(after: minutes(17)) == nil, "nothing to wake for while it runs")
}

@Test func noPollStartsWhilePlaybackIsStarting() {
    var state = WatchState(
        folders: [nas], indexed: [], rescanNetworkFoldersAtLaunch: false,
        pausePollingDuringPlayback: false, now: start)
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
    var state = WatchState(
        folders: [nas], indexed: [], rescanNetworkFoldersAtLaunch: false,
        pausePollingDuringPlayback: true, now: start)
    let engine = FakeEngine(pausePollingDuringPlayback: true)
    engine.report(.playing, to: &state)
    #expect(state.start(now: minutes(30)) == nil)
    engine.report(.stopped, to: &state)
    #expect(state.start(now: minutes(30)) == WatchJob(folder: nas, subtrees: []))
    engine.report(.playing, to: &state)
    #expect(state.holdsRunningScan)
}

@Test func playbackNeverHoldsLocalScans() {
    var state = WatchState(
        folders: [local], indexed: [], rescanNetworkFoldersAtLaunch: false,
        pausePollingDuringPlayback: true, now: start)
    FakeEngine(pausePollingDuringPlayback: true).report(.starting, to: &state)
    #expect(state.start(now: start) == WatchJob(folder: local, subtrees: []))
    #expect(!state.holdsRunningScan)
}

@Test func localChangesBecomeSubtreeScans() {
    var state = WatchState(
        folders: [local, nas], indexed: [], rescanNetworkFoldersAtLaunch: false,
        pausePollingDuringPlayback: false, now: start)
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

@Test func editedDirectoriesAreRescannedInNetworkFoldersToo() {
    var state = WatchState(
        folders: [local, nas], indexed: [], rescanNetworkFoldersAtLaunch: false,
        pausePollingDuringPlayback: true, now: start)
    _ = state.start(now: start)
    state.finished(now: start)
    _ = state.start(now: start)
    state.finished(now: start)
    let engine = FakeEngine(pausePollingDuringPlayback: true)
    engine.report(.playing, to: &state)
    state.directoriesEdited(["/Volumes/Music/C", "/Users/me/Music/A", "/Elsewhere/D"])
    #expect(state.start(now: start) == WatchJob(folder: local, subtrees: ["/Users/me/Music/A"]))
    state.finished(now: start)
    #expect(state.start(now: start) == nil, "the network rescan waits for playback")
    engine.report(.stopped, to: &state)
    #expect(state.start(now: start) == WatchJob(folder: nas, subtrees: ["/Volumes/Music/C"]))
}

@Test func aFailedLocalScanIsRetriedWholeWithABackoff() {
    var state = WatchState(
        folders: [local], indexed: [], rescanNetworkFoldersAtLaunch: false,
        pausePollingDuringPlayback: false, now: start)
    _ = state.start(now: start)
    state.finished(now: start)
    let changed = local.path + "/Album"
    state.directoriesChanged([changed])
    #expect(state.start(now: minutes(1)) == WatchJob(folder: local, subtrees: [changed]))
    let first = state.failed(now: minutes(1))
    #expect(first, "the first failure is reported")
    #expect(state.start(now: minutes(1.5)) == nil, "a full disk doesn't make it spin")
    #expect(state.nextPoll(after: minutes(1.5)) == minutes(2))

    // Each failure in a row doubles the wait, up to the longest, and isn't reported again.
    var now = minutes(2)
    var waits: [Double] = []
    for _ in 0..<6 {
        #expect(state.start(now: now) == WatchJob(folder: local, subtrees: []))
        let reported = state.failed(now: now)
        #expect(!reported)
        let next = state.nextPoll(after: now)!
        waits.append(next.timeIntervalSince(now))
        now = next
    }
    #expect(waits == [120, 240, 480, 900, 900, 900])

    // Held back while a track starts, as polls are.
    FakeEngine().report(.starting, to: &state)
    #expect(state.start(now: now) == nil)
    #expect(state.nextPoll(after: now.addingTimeInterval(-1)) == nil)
    FakeEngine().report(.stopped, to: &state)

    // A scan that finishes ends the run: the next failure is reported and waits a minute.
    #expect(state.start(now: now) == WatchJob(folder: local, subtrees: []))
    state.finished(now: now)
    state.directoriesChanged([changed])
    _ = state.start(now: now)
    let again = state.failed(now: now)
    #expect(again)
    #expect(state.nextPoll(after: now) == now.addingTimeInterval(60))
}

@Test func aFailedPollWaitsForTheNextPollAndIsReportedOnce() {
    var state = WatchState(
        folders: [nas], indexed: [], rescanNetworkFoldersAtLaunch: false,
        pausePollingDuringPlayback: false, now: start)
    _ = state.start(now: start)
    let first = state.failed(now: start)
    #expect(first)
    #expect(state.nextPoll(after: start) == minutes(15))
    _ = state.start(now: minutes(15))
    let second = state.failed(now: minutes(15))
    #expect(!second)
    #expect(state.nextPoll(after: minutes(15)) == minutes(30))
}

@Test func aRelocatedFolderKeepsItsPlaceAndIsPolledAtItsNewPath() {
    var state = WatchState(
        folders: [nas, local], indexed: [], rescanNetworkFoldersAtLaunch: false,
        pausePollingDuringPlayback: false, now: start)
    #expect(state.start(now: start) == WatchJob(folder: local, subtrees: []))
    state.finished(now: start)
    #expect(state.start(now: start) == WatchJob(folder: nas, subtrees: []))
    state.finished(now: minutes(1))
    state.directoriesEdited([nas.path + "/Album"])
    let moved = WatchedFolder(path: "/Volumes/Music-1", kind: .network, pollIntervalMinutes: 15)
    state.relocated([moved, local], now: minutes(2))
    #expect(state.folders == [moved, local])
    // The edit under the old path is dropped; the whole folder is polled at once instead.
    #expect(state.start(now: minutes(2)) == WatchJob(folder: moved, subtrees: []))
    state.finished(now: minutes(3))
    #expect(state.nextPoll(after: minutes(3)) == minutes(18))
}

@Test func rescanNowScansEveryFolderWhilePollsArePausedButNotWhileATrackStarts() {
    var state = WatchState(
        folders: [local, nas], indexed: [nas.path], rescanNetworkFoldersAtLaunch: false,
        pausePollingDuringPlayback: true, now: start)
    #expect(state.start(now: start) == WatchJob(folder: local, subtrees: []))
    state.finished(now: start)
    let engine = FakeEngine(pausePollingDuringPlayback: true)
    engine.report(.starting, to: &state)
    state.rescanEverything()
    #expect(state.start(now: minutes(1)) == WatchJob(folder: local, subtrees: []))
    state.finished(now: minutes(1))
    #expect(state.start(now: minutes(1)) == nil, "a track is starting")
    engine.report(.playing, to: &state)
    let forced = WatchJob(folder: nas, subtrees: [], ignoresPlaybackPause: true)
    #expect(state.start(now: minutes(1)) == forced)
    #expect(!state.holdsRunningScan)
    engine.report(.starting, to: &state)
    #expect(state.holdsRunningScan)
    engine.report(.playing, to: &state)
    state.finished(now: minutes(2))
    #expect(state.start(now: minutes(2)) == nil, "each folder once")
    engine.report(.stopped, to: &state)
    #expect(state.nextPoll(after: minutes(2)) == minutes(17))
}

@Test func rescanScansOnlyTheChosenFoldersWhilePollsArePaused() {
    var state = WatchState(
        folders: [local, nas], indexed: [nas.path], rescanNetworkFoldersAtLaunch: false,
        pausePollingDuringPlayback: true, now: start)
    #expect(state.start(now: start) == WatchJob(folder: local, subtrees: []))
    state.finished(now: start)
    FakeEngine(pausePollingDuringPlayback: true).report(.playing, to: &state)
    state.rescan(wholeFolders: [nas.path])
    let forced = WatchJob(folder: nas, subtrees: [], ignoresPlaybackPause: true)
    #expect(state.start(now: minutes(1)) == forced)
    state.finished(now: minutes(2))
    #expect(state.start(now: minutes(2)) == nil, "the local folder wasn't chosen")
}

@Test func rescanNowLetsAPollPausedForPlaybackGoOn() {
    var state = WatchState(
        folders: [nas], indexed: [], rescanNetworkFoldersAtLaunch: false,
        pausePollingDuringPlayback: true, now: start)
    #expect(state.start(now: start) == WatchJob(folder: nas, subtrees: []))
    FakeEngine(pausePollingDuringPlayback: true).report(.playing, to: &state)
    #expect(state.holdsRunningScan)
    state.rescanEverything()
    #expect(!state.holdsRunningScan)
    state.finished(now: minutes(1))
    #expect(state.start(now: minutes(1)) == nil, "the running scan counted")
}

@Test func theLaunchScansEndWithEachFolderWholeNotWithASubtreeScan() {
    var state = WatchState(
        folders: [local, nas], indexed: [], rescanNetworkFoldersAtLaunch: false,
        pausePollingDuringPlayback: false, now: start)
    state.directoriesChanged([local.path + "/Album"])
    #expect(state.start(now: start) == WatchJob(folder: local, subtrees: [local.path + "/Album"]))
    state.finished(now: start)
    #expect(state.launchScansPending)
    #expect(state.start(now: start) == WatchJob(folder: local, subtrees: []))
    state.finished(now: start)
    #expect(state.launchScansPending, "the network folder's hasn't ended")
    #expect(state.start(now: start) == WatchJob(folder: nas, subtrees: []))
    _ = state.failed(now: start)
    #expect(!state.launchScansPending)

    let kept = WatchState(
        folders: [nas], indexed: [nas.path], rescanNetworkFoldersAtLaunch: false,
        pausePollingDuringPlayback: false, now: start)
    #expect(!kept.launchScansPending)
}

@Test func onlyALocalFoldersLaunchScanHoldsTheFirstSyncBack() {
    var state = WatchState(
        folders: [nas, local], indexed: [], rescanNetworkFoldersAtLaunch: false,
        pausePollingDuringPlayback: false, now: start)
    #expect(state.localLaunchScansPending)
    #expect(state.start(now: start) == WatchJob(folder: local, subtrees: []))
    state.finished(now: start)
    // The network folder's launch scan is still to come, and it doesn't gate.
    #expect(state.launchScansPending)
    #expect(!state.localLaunchScansPending)
    #expect(state.start(now: start) == WatchJob(folder: nas, subtrees: []))
    state.finished(now: start)
    #expect(!state.launchScansPending)
}

@Test func aFailedLocalLaunchScanLiftsTheSyncGate() {
    var state = WatchState(
        folders: [local], indexed: [], rescanNetworkFoldersAtLaunch: false,
        pausePollingDuringPlayback: false, now: start)
    #expect(state.start(now: start) == WatchJob(folder: local, subtrees: []))
    let first = state.failed(now: start)
    #expect(first)
    #expect(!state.localLaunchScansPending)
}

@Test func aNetworkFolderKeptToTheIndexGatesNothing() {
    let state = WatchState(
        folders: [nas], indexed: [nas.path], rescanNetworkFoldersAtLaunch: false,
        pausePollingDuringPlayback: false, now: start)
    #expect(!state.localLaunchScansPending)
}

@Test func aRelocatedLocalFolderGatesUntilItsScanEnds() {
    let moved = WatchedFolder(path: "/Users/me/Moved", kind: .local)
    var state = WatchState(
        folders: [local], indexed: [], rescanNetworkFoldersAtLaunch: false,
        pausePollingDuringPlayback: false, now: start)
    state.relocated([moved], now: start)
    #expect(state.localLaunchScansPending)
    #expect(state.start(now: start) == WatchJob(folder: moved, subtrees: []))
    state.finished(now: start)
    #expect(!state.localLaunchScansPending)
}

@Test func aFolderSetToNeverIsScannedOnlyWhenAskedOrUnfinished() {
    let never = WatchedFolder(path: "/Volumes/Never", kind: .network, pollIntervalMinutes: nil)
    let unfinished = WatchedFolder(
        path: "/Volumes/Unfinished", kind: .network, pollIntervalMinutes: nil)
    // Not even with the launch rescan on, unless its last whole scan didn't finish.
    var state = WatchState(
        folders: [never, unfinished], indexed: [never.path], rescanNetworkFoldersAtLaunch: true,
        pausePollingDuringPlayback: false, now: start)
    #expect(state.leftToTheIndex == [never.path])
    #expect(state.start(now: start) == WatchJob(folder: unfinished, subtrees: []))
    state.finished(now: start)
    #expect(state.nextPoll(after: start) == nil)
    #expect(state.start(now: minutes(100_000)) == nil)
    state.rescan(wholeFolders: [never.path])
    #expect(
        state.start(now: minutes(100_000))
            == WatchJob(folder: never, subtrees: [], ignoresPlaybackPause: true))
    state.finished(now: minutes(100_000))
    #expect(state.nextPoll(after: minutes(100_000)) == nil)
}
