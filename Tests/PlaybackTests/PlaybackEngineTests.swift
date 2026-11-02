import Foundation
import Testing

@testable import Playback

private let urls = (0..<3).map { URL(fileURLWithPath: "/music/\($0).flac") }
private let info = TrackInfo(durationSeconds: 200, outputFormat: "test format")

private struct Broken: Error, CustomStringConvertible {
    var description: String { "broken file" }
}

/// Records what the engine asks of it. Most tests feed events to the engine directly; those
/// about which output an event came from yield them on `events` through `emit`.
private final class FakeOutput: Output, @unchecked Sendable {
    enum Call: Equatable {
        case load(OutputItem.ID, URL, startSeconds: Double, playing: Bool)
        case setNext(OutputItem.ID?, URL?)
        case play, pause, stop
        case seek(Double)
        case volume(Double)
    }

    let events: AsyncStream<OutputEvent>
    let emit: AsyncStream<OutputEvent>.Continuation
    let hasVolume: Bool
    private let lock = NSLock()
    private var recorded: [Call] = []
    private var reported: OutputPosition?

    init(hasVolume: Bool = false) {
        self.hasVolume = hasVolume
        (events, emit) = AsyncStream.makeStream(of: OutputEvent.self)
    }

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

@Test func queuedTracksPlayBeforeTheRestOfTheList() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    await engine.handle(.trackStarted(1, info))
    let (next1, next2, added1, added2) = (
        URL(fileURLWithPath: "/music/next1.flac"), URL(fileURLWithPath: "/music/next2.flac"),
        URL(fileURLWithPath: "/music/added1.flac"), URL(fileURLWithPath: "/music/added2.flac")
    )
    await engine.addToQueue([added1])
    await engine.playNext([next1])
    await engine.addToQueue([added2])
    await engine.playNext([next2])
    var state = await engine.state
    // The latest Play Next goes first; adds keep the order they came in.
    #expect(
        state.order.map { state.queue[$0] }
            == [urls[0], next2, next1, added1, added2, urls[1], urls[2]])
    #expect(state.currentIndex == 0)
    // Once the queued tracks have played, an add goes straight after the current track again.
    await engine.play(at: 4)
    let added3 = URL(fileURLWithPath: "/music/added3.flac")
    await engine.addToQueue([added3])
    state = await engine.state
    #expect(
        state.order.map { state.queue[$0] }
            == [urls[0], next2, next1, added1, added2, added3, urls[1], urls[2]])
}

@Test func addingToAStoppedQueueGoesAfterTheTrackPlayWouldStart() async {
    let output = FakeOutput()
    let engine = PlaybackEngine(output: output)
    await engine.setQueue(urls, first: 1)
    let extra = URL(fileURLWithPath: "/music/extra.flac")
    await engine.addToQueue([extra])
    let state = await engine.state
    #expect(state.order.map { state.queue[$0] } == [urls[0], urls[1], extra, urls[2]])
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

@Test func eachUpdateCarriesThePositionWhenItWasPublished() async {
    let output = FakeOutput()
    let engine = PlaybackEngine(output: output)
    await engine.setQueue(urls)
    await engine.play()
    await engine.handle(.trackStarted(1, info))
    output.setPosition(OutputPosition(item: 1, seconds: 12))
    let updates = await engine.updates()
    await engine.pause()
    output.setPosition(OutputPosition(item: 1, seconds: 99))
    await engine.play()

    var positions: [Double?] = []
    for await update in updates {
        positions.append(update.positionSeconds)
        if update.event == .resumed { break }
    }
    #expect(positions == [12, 12, 99])
}

@Test func playAndPauseTwiceDoNothingTheSecondTime() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    await engine.handle(.trackStarted(1, info))
    _ = output.takeCalls()
    await engine.pause()
    await engine.pause()
    #expect(output.takeCalls() == [.pause])
    #expect(await engine.state.status == .paused)
    await engine.play()
    await engine.play()
    #expect(output.takeCalls() == [.play])
    #expect(await engine.state.status == .playing)
}

@Test func aSeekWhileTheDeviceIsLostIsPublishedAndKeptForResuming() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    await engine.handle(.trackStarted(1, info))
    await engine.handle(.deviceLost(1, positionSeconds: 20))
    let updates = await engine.updates()
    await engine.seek(toSeconds: 50)
    #expect(await engine.position() == 50)
    for await update in updates where update.event != nil {
        #expect(update.event == .seeked(seconds: 50))
        #expect(update.positionSeconds == 50)
        break
    }
}

// MARK: State and events after each command, found missing by mutation testing (ADR 0027).

/// The updates published from now until `act` is done, ended by an underrun the test sends.
private func published(
    _ engine: PlaybackEngine, _ act: () async -> Void
) async -> [PlaybackUpdate] {
    let updates = await engine.updates()
    await act()
    await engine.handle(.underrun(frames: -1))
    var seen: [PlaybackUpdate] = []
    for await update in updates {
        if update.event == .underrun(frames: -1) { break }
        if update.event != nil { seen.append(update) }
    }
    return seen
}

@Test func aNewQueueStopsWhatPlayedAndStartsWhereItSays() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    await engine.handle(.trackStarted(1, info))
    _ = output.takeCalls()
    let other = (0..<3).map { URL(fileURLWithPath: "/other/\($0).flac") }
    let updates = await published(engine) { await engine.setQueue(other, first: 2) }
    #expect(output.takeCalls() == [.stop])
    #expect(updates.map(\.event) == [.queueChanged])
    let state = await engine.state
    #expect(state.queue == other && state.order == [0, 1, 2])
    #expect(state.currentIndex == 2 && state.status == .stopped && state.durationSeconds == nil)
    #expect(await engine.position() == nil)
    await engine.play()
    #expect(output.takeCalls().first == .load(3, other[2], startSeconds: 0, playing: true))
}

@Test func togglePausePausesAndResumes() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    _ = output.takeCalls()
    await engine.togglePause()
    #expect(await engine.state.status == .paused)
    await engine.togglePause()
    #expect(await engine.state.status == .playing)
    #expect(output.takeCalls() == [.pause, .play])
}

@Test func stopIsPublishedAndPlayStartsTheSameTrackAgain() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    await engine.handle(.trackStarted(1, info))
    await engine.next()
    let updates = await published(engine) { await engine.stop() }
    #expect(updates.map(\.event) == [.stopped])
    _ = output.takeCalls()
    await engine.play()
    #expect(output.takeCalls().first == .load(5, urls[1], startSeconds: 0, playing: true))
}

@Test func previousAtExactlyThreeSecondsGoesBackAndAtTheFirstTrackRestarts() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    await engine.handle(.trackStarted(1, info))
    _ = output.takeCalls()
    output.setPosition(OutputPosition(item: 1, seconds: 2))
    let updates = await published(engine) { await engine.previous() }
    #expect(output.takeCalls() == [.seek(0)])
    #expect(updates.map(\.event) == [.seeked(seconds: 0)])
    await engine.next()
    await engine.handle(.trackStarted(3, info))
    _ = output.takeCalls()
    output.setPosition(OutputPosition(item: 3, seconds: 3))
    await engine.previous()
    #expect(output.takeCalls().first == .load(5, urls[0], startSeconds: 0, playing: true))
}

@Test func nextWhileStoppedMovesTheCursorAndSaysSo() async {
    let output = FakeOutput()
    let engine = PlaybackEngine(output: output)
    await engine.setQueue(urls)
    let updates = await published(engine) { await engine.next() }
    #expect(updates.map(\.event) == [.queueChanged])
    #expect(updates.last?.state.currentIndex == 1)
    #expect(await engine.state.currentIndex == 1)
    #expect(output.takeCalls().isEmpty)
}

@Test func repeatAndShuffleAreInTheState() async {
    let output = FakeOutput()
    let engine = PlaybackEngine(output: output, shuffled: { $0.reversed() })
    await engine.setQueue(urls)
    let updates = await published(engine) {
        await engine.setRepeat(.all)
        await engine.setShuffle(true)
    }
    #expect(updates.map(\.event) == [.repeatChanged, .shuffleChanged])
    let state = await engine.state
    #expect(state.repeatMode == .all && state.shuffle && state.order == [0, 2, 1])
}

@Test func playNextIntoAnEmptyQueueStartsIt() async {
    let output = FakeOutput()
    let engine = PlaybackEngine(output: output)
    await engine.playNext(urls)
    #expect(await engine.state.queue == urls)
    #expect(await engine.state.currentIndex == 0)
}

@Test func tracksMoveToTheStartOfTheQueue() async {
    let output = FakeOutput()
    let engine = PlaybackEngine(output: output)
    await engine.setQueue(urls)
    await engine.moveQueueItems([2], to: 0)
    #expect(await engine.state.queue == [urls[2], urls[0], urls[1]])
}

@Test func removingTheCurrentTrackPlaysTheOneThatFollowedIt() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    await engine.handle(.trackStarted(1, info))
    _ = output.takeCalls()
    await engine.removeQueueItems([0])
    #expect(output.takeCalls().first == .load(3, urls[1], startSeconds: 0, playing: true))
}

@Test func removingTheLastTrackWhilePlayingStopsAtTheStart() async {
    let output = FakeOutput()
    let engine = PlaybackEngine(output: output)
    await engine.setQueue(urls, first: 2)
    await engine.play()
    await engine.handle(.trackStarted(1, info))
    _ = output.takeCalls()
    await engine.removeQueueItems([2])
    #expect(output.takeCalls() == [.stop])
    let state = await engine.state
    #expect(state.status == .stopped && state.currentIndex == 0)
    await engine.play()
    #expect(output.takeCalls().first == .load(2, urls[0], startSeconds: 0, playing: true))
}

@Test func editsWhileStoppedKeepTheTrackPlayWouldStart() async {
    let output = FakeOutput()
    let engine = PlaybackEngine(output: output)
    await engine.setQueue(urls, first: 2)
    let updates = await published(engine) { await engine.removeQueueItems([0]) }
    #expect(updates.map(\.event) == [.queueChanged])
    #expect(await engine.state.currentIndex == 1)
    await engine.play()
    #expect(output.takeCalls().first == .load(1, urls[2], startSeconds: 0, playing: true))
}

@Test func theRemovedNextTrackIsReplacedEvenWhenTheNewOneHasItsNumber() async {
    let output = FakeOutput()
    let engine = PlaybackEngine(output: output)
    await engine.setQueue(urls, first: 2)
    await engine.setRepeat(.all)
    await engine.play()
    await engine.handle(.trackStarted(1, info))
    _ = output.takeCalls()
    // The next track wraps to the first, which goes; the new first is next.
    await engine.removeQueueItems([0])
    #expect(output.takeCalls() == [.setNext(3, urls[1])])
}

@Test func thePositionIsOnlyThatOfTheTracksTheEngineLoaded() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    output.setPosition(OutputPosition(item: 1, seconds: 5))
    #expect(await engine.position() == 5)
    output.setPosition(OutputPosition(item: 2, seconds: 6))
    #expect(await engine.position() == 6)
    output.setPosition(OutputPosition(item: 9, seconds: 7))
    #expect(await engine.position() == nil)
}

@Test func movingOnClearsTheOldTracksDurationAndPointsAtTheNewOne() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    await engine.handle(.trackStarted(1, info))
    await engine.next()
    let state = await engine.state
    #expect(state.durationSeconds == nil && state.currentIndex == 1)
}

@Test func aStartedTrackSetsTheFormatAndAFormatChangeUpdatesIt() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    let updates = await published(engine) {
        await engine.handle(.trackStarted(1, info))
        await engine.handle(.formatChanged(1, FormatChange(from: "a", to: "b", switchSeconds: nil)))
        await engine.handle(.trackEnded(1))
    }
    #expect(
        updates.map(\.event) == [
            .trackStarted(index: 0),
            .formatChanged(FormatChange(from: "a", to: "b", switchSeconds: nil)),
            .trackEnded(index: 0),
        ])
    #expect(updates[0].state.outputFormat == "test format")
    #expect(await engine.state.outputFormat == "b")
}

@Test func theQueueFinishedLeavesNothingLoaded() async {
    let output = FakeOutput()
    let engine = await playing([urls[0]], output)
    await engine.handle(.trackStarted(1, info))
    output.setPosition(OutputPosition(item: 1, seconds: 199))
    await engine.handle(.finished(1))
    let state = await engine.state
    #expect(state.status == .stopped && state.durationSeconds == nil && state.currentIndex == 0)
    #expect(await engine.position() == nil)
    _ = output.takeCalls()
    await engine.play()
    #expect(output.takeCalls().first == .load(2, urls[0], startSeconds: 0, playing: true))
}

@Test func theDeviceLostOnTheNextTrackResumesThatTrackAtTheStartOfTheOthers() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    await engine.handle(.trackStarted(1, info))
    // Lost with no item named: the current track picks up from its start.
    await engine.handle(.deviceLost(nil, positionSeconds: 30))
    #expect(await engine.position() == 0)
    _ = output.takeCalls()
    await engine.play()
    #expect(
        output.takeCalls() == [
            .load(3, urls[0], startSeconds: 0, playing: true), .setNext(4, urls[1]),
        ])
}

@Test func anOutputFailureNamingAnotherItemIsIgnored() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    await engine.handle(.trackStarted(1, info))
    await engine.handle(.failed(9, Broken()))
    #expect(await engine.state.status == .playing)
    await engine.handle(.failed(nil, Broken()))
    #expect(await engine.state.status == .stopped)
    #expect(await engine.position() == nil)
    _ = output.takeCalls()
    await engine.play()
    #expect(output.takeCalls().first == .load(3, urls[0], startSeconds: 0, playing: true))
}

@Test func playbackStopsAfterAFewFailedTracksInARowAndSaysSoOnce() async {
    let five = (0..<5).map { URL(fileURLWithPath: "/music/\($0).flac") }
    let output = FakeOutput()
    let engine = await playing(five, output)
    let updates = await engine.updates()
    var id = 1
    for _ in 0..<PlaybackEngine.failureLimit {
        await engine.handle(.trackFailed(id, Broken()))
        await engine.handle(.finished(id))
        id += 3  // the skip, then the load and its next
    }
    #expect(await engine.state.status == .stopped)
    // The first track's, and one for each failure but the last.
    let loads = output.takeCalls().filter { if case .load = $0 { true } else { false } }
    #expect(loads.count == PlaybackEngine.failureLimit)
    // Ends the events below should playback still be going.
    await engine.stop()

    var events: [PlaybackEvent] = []
    for await update in updates {
        guard let event = update.event else { continue }
        events.append(event)
        if case .failed = event { break }
        if event == .stopped { break }
    }
    #expect(events.filter { if case .trackFailed = $0 { true } else { false } }.count == 3)
    #expect(events.last == .failed(reason: "3 tracks in a row couldn't play"))
    #expect(!events.contains(.finished))
}

@Test func whenEveryTrackHasFailedTheNextIsCleared() async {
    let output = FakeOutput()
    let engine = await playing(Array(urls.prefix(2)), output)
    await engine.handle(.trackFailed(1, Broken()))
    _ = output.takeCalls()
    await engine.handle(.trackFailed(2, Broken()))
    #expect(output.takeCalls() == [.setNext(nil, nil)])
}

@Test func failuresInARowStartAgainWithANewQueueAPlayOrAStartedTrack() async {
    let output = FakeOutput()
    let engine = PlaybackEngine(output: output)
    await engine.setRepeat(.all)
    await engine.setQueue(Array(urls.prefix(2)))
    await engine.play()
    // The next track fails once: the engine hands over the first again, as repeat all wraps.
    await engine.handle(.trackFailed(2, Broken()))
    #expect(output.takeCalls().last == .setNext(3, urls[0]))
    await engine.setQueue(Array(urls.prefix(2)))
    await engine.play()
    _ = output.takeCalls()
    await engine.handle(.trackFailed(5, Broken()))
    #expect(output.takeCalls() == [.setNext(6, urls[0])])
    await engine.stop()
    await engine.play()
    _ = output.takeCalls()
    await engine.handle(.trackFailed(8, Broken()))
    #expect(output.takeCalls() == [.setNext(9, urls[0])])

    // Three tracks: failures between two that start don't add up.
    let three = PlaybackEngine(output: output)
    await three.setRepeat(.all)
    await three.setQueue(urls)
    await three.play()
    await three.handle(.trackStarted(1, info))
    await three.handle(.trackFailed(2, Broken()))
    await three.handle(.trackStarted(3, info))
    await three.handle(.trackFailed(4, Broken()))
    _ = output.takeCalls()
    await three.handle(.trackFailed(5, Broken()))
    #expect(output.takeCalls() == [.setNext(6, urls[2])])
}

@Test func removingTheTrackPlayWouldStartFromTheEndGoesBackToTheStart() async {
    let output = FakeOutput()
    let engine = PlaybackEngine(output: output)
    await engine.setQueue(urls, first: 2)
    await engine.removeQueueItems([2])
    #expect(await engine.state.currentIndex == 0)
}

@Test func aTrackChosenAfterOneFailedFinishesNormally() async {
    let output = FakeOutput()
    let engine = await playing(Array(urls.prefix(2)), output)
    await engine.handle(.trackStarted(1, info))
    await engine.handle(.trackFailed(1, Broken()))
    await engine.next()
    await engine.handle(.trackStarted(3, info))
    _ = output.takeCalls()
    await engine.handle(.finished(3))
    #expect(output.takeCalls().isEmpty)
    #expect(await engine.state.status == .stopped)
}

@Test func aNextTrackStartedAfterAFailedOneFinishesNormally() async {
    let output = FakeOutput()
    let engine = await playing(Array(urls.prefix(2)), output)
    await engine.handle(.trackStarted(1, info))
    await engine.handle(.trackFailed(1, Broken()))
    await engine.handle(.trackStarted(2, info))
    _ = output.takeCalls()
    await engine.handle(.finished(2))
    #expect(output.takeCalls().isEmpty)
}

@Test func aNewQueueForgetsWhereALostDeviceWasAndTheOldNextTrack() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    await engine.handle(.trackStarted(1, info))
    await engine.setQueue(urls)
    output.setPosition(OutputPosition(item: 2, seconds: 4))
    #expect(await engine.position() == nil)
    await engine.play()
    await engine.handle(.trackStarted(3, info))
    await engine.handle(.deviceLost(3, positionSeconds: 30))
    await engine.setQueue(urls)
    _ = output.takeCalls()
    await engine.play()
    #expect(output.takeCalls().first == .load(5, urls[0], startSeconds: 0, playing: true))
}

@Test func afterTheLastTrackFinishesPlayStartsAtTheFirst() async {
    let output = FakeOutput()
    let engine = await playing(Array(urls.prefix(2)), output)
    await engine.handle(.trackStarted(1, info))
    await engine.handle(.trackStarted(2, info))
    output.setPosition(OutputPosition(item: 2, seconds: 199))
    await engine.handle(.finished(2))
    #expect(await engine.position() == nil)
    _ = output.takeCalls()
    await engine.play()
    #expect(output.takeCalls().first == .load(3, urls[0], startSeconds: 0, playing: true))
}

@Test func anOutputFailureForgetsTheTracksAndWhereTheDeviceWasLost() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    await engine.handle(.trackStarted(1, info))
    output.setPosition(OutputPosition(item: 2, seconds: 3))
    await engine.handle(.failed(nil, Broken()))
    #expect(await engine.position() == nil)
    output.setPosition(OutputPosition(item: 1, seconds: 3))
    #expect(await engine.position() == nil)
    await engine.play()
    await engine.handle(.deviceLost(3, positionSeconds: 30))
    await engine.handle(.failed(nil, Broken()))
    _ = output.takeCalls()
    await engine.play()
    #expect(output.takeCalls().first == .load(5, urls[0], startSeconds: 0, playing: true))
}

@Test func aNextTrackGivenUpOnIsntReportedAsPlaying() async {
    let output = FakeOutput()
    let engine = await playing(Array(urls.prefix(2)), output)
    await engine.handle(.trackFailed(1, Broken()))
    await engine.handle(.trackFailed(2, Broken()))
    output.setPosition(OutputPosition(item: 2, seconds: 1))
    #expect(await engine.position() == nil)
}

@Test func afterAQueueFinishesFromALaterTrackPlayStartsAtTheFirst() async {
    let output = FakeOutput()
    let engine = await playing(Array(urls.prefix(2)), output)
    await engine.next()
    await engine.handle(.trackStarted(3, info))
    await engine.handle(.finished(3))
    _ = output.takeCalls()
    await engine.play()
    #expect(output.takeCalls().first == .load(4, urls[0], startSeconds: 0, playing: true))
}

@Test func shufflingThatKeepsTheNextTrackFollowsItToItsNewPlace() async {
    let output = FakeOutput()
    let four = (0..<4).map { URL(fileURLWithPath: "/music/\($0).flac") }
    // Shuffling around entry 1 puts entry 2, already next, straight after it.
    let engine = PlaybackEngine(
        output: output, shuffled: { $0 == [0, 2, 3] ? [2, 0, 3] : $0 })
    await engine.setQueue(four, first: 1)
    await engine.play()
    await engine.handle(.trackStarted(1, info))
    await engine.setShuffle(true)
    #expect(await engine.state.order == [1, 2, 0, 3])
    await engine.handle(.trackStarted(2, info))
    #expect(await engine.state.currentIndex == 2)
}

@Test func aLateStartOfTheNextTrackAfterTheDeviceWasLostIsIgnored() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    await engine.handle(.trackStarted(1, info))
    await engine.handle(.deviceLost(1, positionSeconds: 30))
    await engine.handle(.trackStarted(2, info))
    #expect(await engine.state.currentIndex == 0)
    #expect(await engine.position() == 30)
}

/// Waits up to two seconds for `check` to hold, and fails saying what it was waiting for.
private func eventually(_ what: String, _ check: @escaping @Sendable () async -> Bool) async {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        if await check() { return }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    Issue.record("timed out waiting for \(what)")
}

@Test func anotherOutputTakesOverWhereTheTrackWasAndTheOldOneIsStopped() async {
    let device = FakeOutput()
    let renderer = FakeOutput()
    let engine = await playing(urls, device)
    await engine.handle(.trackStarted(1, info))
    device.setPosition(OutputPosition(item: 1, seconds: 37))
    _ = device.takeCalls()

    await engine.use(renderer)
    #expect(device.takeCalls() == [.stop])
    #expect(
        renderer.takeCalls() == [
            .load(3, urls[0], startSeconds: 37, playing: true), .setNext(4, urls[1]),
        ])
    await engine.pause()
    #expect(renderer.takeCalls() == [.pause])
    #expect(device.takeCalls() == [])

    // Paused, it moves back paused.
    renderer.setPosition(OutputPosition(item: 3, seconds: 40))
    await engine.use(device)
    #expect(renderer.takeCalls() == [.stop])
    #expect(
        device.takeCalls() == [
            .load(5, urls[0], startSeconds: 40, playing: false), .setNext(6, urls[1]),
        ])
    #expect(await engine.state.status == .paused)
}

@Test func withNothingLoadedSwitchingOutputsSendsNothing() async {
    let device = FakeOutput()
    let renderer = FakeOutput()
    let engine = PlaybackEngine(output: device)
    await engine.setQueue(urls)
    await engine.use(renderer)
    await engine.use(renderer)
    #expect(device.takeCalls() == [])
    #expect(renderer.takeCalls() == [])
    await engine.play()
    #expect(renderer.takeCalls().first == .load(1, urls[0], startSeconds: 0, playing: true))
}

@Test func onlyTheCurrentOutputsEventsCount() async {
    let device = FakeOutput()
    let renderer = FakeOutput()
    let engine = await playing(urls, device)
    await engine.use(renderer)
    // The old output reports what it had: the engine has moved on, so it changes nothing.
    device.emit.yield(.failed(nil, Broken()))
    renderer.emit.yield(.trackStarted(3, info))
    await eventually("the renderer's track to start") {
        await engine.state.durationSeconds == 200
    }
    #expect(await engine.state.status == .playing)

    // Back on the device, the renderer's events are the ones ignored.
    await engine.use(device)
    renderer.emit.yield(.failed(nil, Broken()))
    device.emit.yield(.trackStarted(5, TrackInfo(durationSeconds: 99, outputFormat: nil)))
    await eventually("the device's track to start") {
        await engine.state.durationSeconds == 99
    }
    #expect(await engine.state.status == .playing)
}

@Test func aFailedSeekIsCorrectedToWherePlaybackIs() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    await engine.handle(.trackStarted(1, info))
    let seen = await published(engine) {
        await engine.seek(toSeconds: 90)
        await engine.handle(.seekFailed(1, positionSeconds: 12))
        // About an item since replaced: ignored.
        await engine.handle(.seekFailed(7, positionSeconds: 3))
    }
    #expect(seen.map(\.event) == [.seeked(seconds: 90), .seeked(seconds: 12)])
}

@Test func theEngineFollowsAnOutputThatPausedOrPlayedOnItsOwn() async {
    let output = FakeOutput()
    let engine = await playing(urls, output)
    await engine.handle(.trackStarted(1, info))
    _ = output.takeCalls()
    let seen = await published(engine) {
        await engine.handle(.transportChanged(1, playing: false))
        await engine.handle(.transportChanged(1, playing: false))
        await engine.handle(.transportChanged(1, playing: true))
        await engine.handle(.transportChanged(2, playing: false))
    }
    #expect(seen.map(\.event) == [.paused, .resumed])
    #expect(await engine.state.status == .playing)
    // Nothing is sent back to the output: it already plays as the engine now says.
    #expect(!output.takeCalls().contains { $0 == .play || $0 == .pause })
}
