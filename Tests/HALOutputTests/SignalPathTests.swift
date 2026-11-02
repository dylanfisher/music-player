import Foundation
import Testing

@testable import Fixtures
@testable import HALOutput
@testable import Playback

/// A rig whose signal paths are collected, with the first track of a 44.1 kHz 16-bit album
/// loaded and paused, so the device's state can change under a track that stays put.
private func pausedRig(digitalVolume: Bool = false) async throws -> (Rig, Collected<SignalPath>) {
    let album = try album(44_100, 16)
    let rig = try await Rig(speed: 1, digitalVolume: digitalVolume)
    let paths = Collected(rig.output.signalPaths)
    await rig.engine.setQueue(album.tracks)
    await rig.engine.play()
    try await rig.wait(for: .trackStarted(index: 0))
    await rig.engine.pause()
    try await waitForPath(paths) { signalVerdict($0) == .bitPerfect }
    return (rig, paths)
}

/// The first path from now that matches, failing with every path seen if none does in time.
@discardableResult
private func waitForPath(
    _ paths: Collected<SignalPath>, seconds: Double = 20,
    _ matches: (SignalPath) -> Bool
) async throws -> SignalPath {
    let deadline = Date().addingTimeInterval(seconds)
    while true {
        let path = try await paths.next(within: deadline.timeIntervalSinceNow)
        if matches(path) { return path }
    }
}

private func state(_ path: SignalPath) -> DeviceState {
    switch path.sink {
    case .device(let sink): sink.state
    case .renderer: .unreadable("a device output published a renderer")
    }
}

@Test func aTrackAtTheDevicesRateIsBitPerfectWithTheFilesFormat() async throws {
    let (_, paths) = try await pausedRig()
    let track = try #require(paths.returned.last?.track)
    #expect(track.file.formatID == "flac")
    #expect(track.file.bitsPerChannel == 16)
    #expect(track.file.sampleRateHz == 44_100)
    #expect(track.decoded.bitsPerChannel == 32)
}

@Test func anotherAppChangingTheRateShowsAsResampling() async throws {
    let (rig, paths) = try await pausedRig()
    rig.device.changeRate(to: 48_000)
    try await waitForPath(paths) {
        signalVerdict($0) == .changed([.deviceResamples(fromHz: 44_100, toHz: 48_000)])
    }
}

@Test func aDeviceVolumeBelowUnityIsNamed() async throws {
    let (rig, paths) = try await pausedRig()
    let half = VolumeControl(.virtualMain, scalar: 0.5)
    rig.device.setVolumes([half, VolumeControl(.main, scalar: 1)])
    try await waitForPath(paths) { signalVerdict($0) == .changed([.deviceVolume(half)]) }
    rig.device.setVolumes([VolumeControl(.virtualMain, scalar: 1)])
    try await waitForPath(paths) { signalVerdict($0) == .bitPerfect }
}

@Test func theDigitalVolumeBelowUnityIsNamed() async throws {
    let (rig, paths) = try await pausedRig(digitalVolume: true)
    try await rig.engine.setVolume(0.5)
    try await waitForPath(paths) { signalVerdict($0) == .changed([.digitalVolume(gain: 0.5)]) }
    try await rig.engine.setVolume(1)
    try await waitForPath(paths) { signalVerdict($0) == .bitPerfect }
}

@Test func losingHogModeToAnotherProcessIsNamed() async throws {
    let (rig, paths) = try await pausedRig()
    rig.device.hogMode(heldBy: 4242)
    try await waitForPath(paths) { signalVerdict($0) == .changed([.hogModeHeld(byPID: 4242)]) }
}

@Test func theDeviceGoingAndComingBackMidTrackIsFollowed() async throws {
    let (rig, paths) = try await pausedRig()
    rig.device.unplug()
    try await waitForPath(paths) { state($0) == .notConnected && $0.track == nil }
    rig.device.plugIn()
    try await waitForPath(paths) {
        if case .connected = state($0) { true } else { false }
    }
    await rig.engine.play()
    try await waitForPath(paths) { $0.track != nil && signalVerdict($0) == .bitPerfect }
}

@Test func closingTheOutputStopsWatchingTheDevice() async throws {
    let rig = try await Rig()
    #expect(rig.device.isWatched)
    rig.output.close()
    #expect(!rig.device.isWatched)
}

@Test func aSteadyPlaybackPassBuildsNoSignalPath() async throws {
    let album = try album(44_100, 16)
    let rig = try await Rig(speed: 1)
    let paths = Collected(rig.output.signalPaths)
    await rig.engine.setQueue(album.tracks)
    await rig.engine.play()
    try await rig.wait(for: .trackStarted(index: 0))
    try await waitForPath(paths) { signalVerdict($0) == .bitPerfect }
    let before = rig.output.signalPathBuilds
    // About 30 control passes, well inside the first track's second.
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(rig.output.signalPathBuilds == before)
}
