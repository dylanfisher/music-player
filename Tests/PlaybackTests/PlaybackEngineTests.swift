import Foundation
import Testing

@testable import Playback

private let urls = (0..<3).map { URL(fileURLWithPath: "/music/\($0).flac") }
private let info = TrackInfo(durationSeconds: 200, outputFormat: "test format")

private struct Broken: Error, CustomStringConvertible {
    var description: String { "broken file" }
}

/// Records what the engine asks of it. Tests feed events to the engine directly, so nothing is
/// ever yielded on `events`.
private final class FakeOutput: Output, @unchecked Sendable {
    enum Call: Equatable {
        case load(OutputItem.ID, URL, startSeconds: Double, playing: Bool)
        case setNext(OutputItem.ID?, URL?)
        case play, pause, stop
        case seek(Double)
        case volume(Double)
    }

    let events = AsyncStream<OutputEvent> { _ in }
    let hasVolume: Bool
    private let lock = NSLock()
    private var recorded: [Call] = []
    private var reported: OutputPosition?

    init(hasVolume: Bool = false) { self.hasVolume = hasVolume }

    /// Returns the calls since the last time, and forgets them.
    func takeCalls() -> [Call] {
        lock.withLock {
            defer { recorded = [] }
            return recorded
        }
    }

    func setPosition(_ position: OutputPosition?) { lock.withLock { reported = position } }

    private func record(_ call: Call) { lock.withLock { recorded.append(call) } }

    func load(_ item: OutputItem, startSeconds: Double, playing: Bool) {
        record(.load(item.id, item.url, startSeconds: startSeconds, playing: playing))
    }
    func setNext(_ item: OutputItem?) { record(.setNext(item?.id, item?.url)) }
    func play() { record(.play) }
    func pause() { record(.pause) }
    func stop() { record(.stop) }
    func seek(toSeconds seconds: Double) { record(.seek(seconds)) }
    func setVolume(_ gain: Double) { record(.volume(gain)) }
    func position() -> OutputPosition? { lock.withLock { reported } }
    func close() {}
}

private func playing(_ urls: [URL], _ output: FakeOutput) async -> PlaybackEngine {
    let engine = PlaybackEngine(output: output, shuffled: { $0.reversed() })
    await engine.setQueue(urls)
    await engine.play()
    return engine
}

@Test func playsTheQueueInOrderHandingOverEachNextTrack() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    #expect(
        output.takeCalls() == [
            .load(1, urls[0], startSeconds: 0, playing: true), .setNext(2, urls[1]),
        ])

    await engine.handle(.trackStarted(1, info))
    await engine.handle(.trackStarted(2, info))
    #expect(output.takeCalls() == [.setNext(3, urls[2])])
    #expect(await engine.state.currentIndex == 1)
    #expect(await engine.state.durationSeconds == 200)

    await engine.handle(.trackStarted(3, info))
    // The output's next track was used up, so there's nothing to clear.
    #expect(output.takeCalls() == [])
    await engine.handle(.finished(3))
    #expect(await engine.state.status == .stopped)
    #expect(await engine.state.currentIndex == 0)
}

@Test func updatesStartWithTheStateAndCarryEachEvent() async {
    let output = FakeOutput()
    let engine = PlaybackEngine(output: output)
    let updates = await engine.updates()
    await engine.setQueue(urls)
    await engine.play()
    await engine.handle(.trackStarted(1, info))
    await engine.pause()

    var events: [PlaybackEvent?] = []
    for await update in updates {
        events.append(update.event)
        if update.event == .paused {
            #expect(update.state.status == .paused)
            break
        }
    }
    #expect(events == [nil, .queueChanged, .resumed, .trackStarted(index: 0), .paused])
    #expect(output.takeCalls().last == .pause)
}

@Test func previousRestartsATrackPastThreeSecondsAndGoesBackBeforeThat() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    await engine.handle(.trackStarted(1, info))
    await engine.next()
    _ = output.takeCalls()
    await engine.handle(.trackStarted(3, info))
    _ = output.takeCalls()

    output.setPosition(OutputPosition(item: 3, seconds: 10))
    await engine.previous()
    #expect(output.takeCalls() == [.seek(0)])

    output.setPosition(OutputPosition(item: 3, seconds: 1))
    await engine.previous()
    #expect(
        output.takeCalls() == [
            .load(5, urls[0], startSeconds: 0, playing: true), .setNext(6, urls[1]),
        ])
}

@Test func eventsAboutAReplacedItemAreIgnored() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    await engine.next()
    _ = output.takeCalls()

    // Item 2 was the next track before the skip replaced everything.
    await engine.handle(.trackStarted(2, info))
    await engine.handle(.finished(1))
    #expect(output.takeCalls() == [])
    #expect(await engine.state.status == .playing)
    #expect(await engine.state.durationSeconds == nil)
}

@Test func aNextTrackThatFailsIsSkipped() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    _ = output.takeCalls()
    await engine.handle(.trackFailed(2, Broken()))
    #expect(output.takeCalls() == [.setNext(3, urls[2])])
}

@Test func aCurrentTrackThatFailsMovesOnWhenItFinishes() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    await engine.setRepeat(.one)
    _ = output.takeCalls()
    await engine.handle(.trackFailed(1, Broken()))
    await engine.handle(.finished(1))
    // Repeat one would replay the broken track; a failure skips on instead.
    #expect(
        output.takeCalls() == [
            .setNext(4, urls[1]), .load(5, urls[1], startSeconds: 0, playing: true),
            .setNext(6, urls[1]),
        ])
}

@Test func aQueueOfBrokenFilesEndsInsteadOfLooping() async {
    let output = FakeOutput()
    let engine = await playing(Array(urls.prefix(2)), output)
    await engine.setRepeat(.all)
    var id = 1
    for _ in 0..<2 {
        await engine.handle(.trackFailed(id, Broken()))
        await engine.handle(.finished(id))
        id += 3  // the skip, then the load and its next
    }
    #expect(await engine.state.status == .stopped)
}

@Test func aFinishThatRacedTheNextTrackLoadsIt() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    await engine.handle(.trackStarted(1, info))
    _ = output.takeCalls()
    await engine.handle(.finished(1))
    #expect(
        output.takeCalls() == [
            .load(3, urls[1], startSeconds: 0, playing: true), .setNext(4, urls[2]),
        ])
}

@Test func losingTheDevicePausesAndPlayResumesWhereItWas() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    await engine.handle(.trackStarted(1, info))
    await engine.handle(.deviceLost(1, positionSeconds: 42))
    #expect(await engine.state.status == .paused)
    #expect(await engine.state.device == .lost)
    #expect(await engine.position() == 42)

    await engine.handle(.deviceReturned)
    #expect(await engine.state.device == .returned)
    _ = output.takeCalls()
    await engine.play()
    #expect(
        output.takeCalls() == [
            .load(3, urls[0], startSeconds: 42, playing: true), .setNext(4, urls[1]),
        ])
    await engine.handle(.trackStarted(3, info))
    #expect(await engine.state.device == .connected)
}

@Test func repeatOneHandsOverTheSameTrackAgain() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    _ = output.takeCalls()
    await engine.setRepeat(.one)
    #expect(output.takeCalls() == [.setNext(3, urls[0])])
}

@Test func shuffleReordersWhatComesNext() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    _ = output.takeCalls()
    await engine.setShuffle(true)
    // Reversed after the current track: 0, 2, 1.
    #expect(output.takeCalls() == [.setNext(3, urls[2])])
}

@Test func nextPastTheLastTrackStops() async {
    let output = FakeOutput()
    let engine = await playing(Array(urls.prefix(1)), output)
    _ = output.takeCalls()
    await engine.next()
    #expect(output.takeCalls() == [.stop])
    #expect(await engine.state.status == .stopped)
}

@Test func volumeNeedsAnOutputThatHasOne() async throws {
    let engine = PlaybackEngine(output: FakeOutput())
    await #expect(throws: PlaybackError.self) { try await engine.setVolume(0.5) }

    let output = FakeOutput(hasVolume: true)
    try await PlaybackEngine(output: output).setVolume(0.5)
    #expect(output.takeCalls() == [.volume(0.5)])
}

@Test func anOutputFailureStops() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    await engine.handle(.failed(1, Broken()))
    #expect(await engine.state.status == .stopped)
    _ = output.takeCalls()
    await engine.play()
    #expect(output.takeCalls().first == .load(3, urls[0], startSeconds: 0, playing: true))
}

@Test func aRepeatOrShuffleChangeThatKeepsTheNextTrackSendsNothing() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    _ = output.takeCalls()
    let updates = await engine.updates()
    await engine.setRepeat(.all)
    await engine.setRepeat(.all)
    await engine.setShuffle(false)
    #expect(output.takeCalls() == [])
    var events: [PlaybackEvent?] = []
    for await update in updates {
        events.append(update.event)
        if events.count == 2 { break }
    }
    #expect(events == [nil, .repeatChanged])
}

@Test func losingTheDeviceRightAfterTheNextTrackStartedResumesThatTrack() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    // The output started item 2 and lost the device before the engine heard of the start.
    await engine.handle(.deviceLost(2, positionSeconds: 5))
    #expect(await engine.state.currentIndex == 1)
    _ = output.takeCalls()
    await engine.play()
    #expect(output.takeCalls().first == .load(3, urls[1], startSeconds: 5, playing: true))
}

@Test func choosingATrackGivesTheQueueAnotherChanceAfterFailures() async {
    let output = FakeOutput()
    let engine = await playing(Array(urls.prefix(2)), output)
    await engine.setRepeat(.all)
    // Track 1 fails, and so does the next one queued after it.
    await engine.handle(.trackFailed(1, Broken()))
    await engine.handle(.trackFailed(2, Broken()))
    _ = output.takeCalls()
    // Choosing a track starts the count again, so a failure there still moves on.
    await engine.next()
    let loaded = output.takeCalls()
    guard case .load(let id, _, _, _) = loaded.first else {
        Issue.record("expected a load, got \(loaded)")
        return
    }
    await engine.handle(.trackFailed(id, Broken()))
    await engine.handle(.finished(id))
    #expect(output.takeCalls().contains { if case .load = $0 { true } else { false } })
}

@Test func updatesEndWhenTheOutputCloses() async {
    let (events, continuation) = AsyncStream.makeStream(of: OutputEvent.self)
    let output = ClosingOutput(events: events)
    let engine = PlaybackEngine(output: output)
    let updates = await engine.updates()
    continuation.finish()
    var count = 0
    for await _ in updates { count += 1 }
    #expect(count == 1)
}

/// An output whose event stream the test ends.
private final class ClosingOutput: Output, @unchecked Sendable {
    let events: AsyncStream<OutputEvent>
    let hasVolume = false
    init(events: AsyncStream<OutputEvent>) { self.events = events }
    func load(_ item: OutputItem, startSeconds: Double, playing: Bool) {}
    func setNext(_ item: OutputItem?) {}
    func play() {}
    func pause() {}
    func stop() {}
    func seek(toSeconds seconds: Double) {}
    func setVolume(_ gain: Double) {}
    func position() -> OutputPosition? { nil }
    func close() {}
}

@Test func playNextQueuesAfterTheCurrentTrackAndHandsItOver() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    await engine.handle(.trackStarted(1, info))
    _ = output.takeCalls()
    let extra = URL(fileURLWithPath: "/music/extra.flac")
    await engine.playNext([extra])
    #expect(output.takeCalls() == [.setNext(3, extra)])
    let state = await engine.state
    #expect(state.order.map { state.queue[$0] } == [urls[0], extra, urls[1], urls[2]])
    #expect(state.currentIndex == 0)
}

@Test func movingTracksKeepsTheCurrentOnePlaying() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    await engine.handle(.trackStarted(1, info))
    _ = output.takeCalls()
    // The current track moves to the end; nothing follows it, so the output's next is cleared.
    await engine.moveQueueItems([0], to: 3)
    #expect(output.takeCalls() == [.setNext(nil, nil)])
    var state = await engine.state
    #expect(state.order.map { state.queue[$0] } == [urls[1], urls[2], urls[0]])
    #expect(state.currentIndex == 2)
    #expect(state.status == .playing)
    // Moving another track in after it makes that the next one.
    await engine.moveQueueItems([0], to: 3)
    #expect(output.takeCalls() == [.setNext(3, urls[1])])
    state = await engine.state
    #expect(state.order.map { state.queue[$0] } == [urls[2], urls[0], urls[1]])
}

@Test func removingTheNextTrackReplacesItAndRemovingTheCurrentOneMovesOn() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    await engine.handle(.trackStarted(1, info))
    _ = output.takeCalls()
    await engine.removeQueueItems([1])
    #expect(output.takeCalls() == [.setNext(3, urls[2])])
    await engine.removeQueueItems([0])
    #expect(output.takeCalls() == [.load(4, urls[2], startSeconds: 0, playing: true)])
    var state = await engine.state
    #expect(state.queue == [urls[2]])
    #expect(state.currentIndex == 0)
    await engine.removeQueueItems([0])
    state = await engine.state
    #expect(state.queue.isEmpty)
    #expect(state.status == .stopped)
    #expect(state.currentIndex == nil)
}

@Test func playAtJumpsToAPositionInPlayOrder() async {
    let output = FakeOutput()
    let engine = PlaybackEngine(output: output)
    await engine.setQueue(urls)
    await engine.play(at: 2)
    #expect(output.takeCalls().first == .load(1, urls[2], startSeconds: 0, playing: true))
    #expect(await engine.state.status == .playing)
    #expect(await engine.state.currentIndex == 2)
}

@Test func aSeekIsPublishedWithWhereItWentAndNothingLoadedPublishesNothing() async {
    let output = FakeOutput()
    let engine = PlaybackEngine(output: output)
    let updates = await engine.updates()
    await engine.setQueue(urls)
    await engine.seek(toSeconds: 30)
    await engine.play()
    await engine.seek(toSeconds: -5)
    await engine.seek(toSeconds: 42)

    var events: [PlaybackEvent?] = []
    for await update in updates {
        events.append(update.event)
        if update.event == .seeked(seconds: 42) { break }
    }
    #expect(
        events == [nil, .queueChanged, .resumed, .seeked(seconds: 0), .seeked(seconds: 42)])
}
