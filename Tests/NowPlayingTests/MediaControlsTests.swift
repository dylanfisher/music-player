import Artwork
import Commands
import CoreGraphics
import Foundation
import ImageIO
import Metadata
import Settings
import Testing

@testable import Library
@testable import NowPlaying
@testable import Playback

private let urls = ["/m/a.flac", "/m/b.flac"].map(URL.init(fileURLWithPath:))

@MainActor
private final class FakeRemote: RemoteCommandCenter {
    var handler: (@MainActor @Sendable (RemoteAction) -> Bool)?
    var enabledSets: [Set<RemoteCommand>] = []

    func start(_ handler: @escaping @MainActor @Sendable (RemoteAction) -> Bool) {
        self.handler = handler
    }

    func setEnabled(_ enabled: Set<RemoteCommand>) { enabledSets.append(enabled) }

    func send(_ action: RemoteAction) -> Bool { handler?(action) ?? false }
}

@MainActor
private final class FakeCenter: NowPlayingCenter {
    var shown: [NowPlayingInfo?] = []
    func show(_ info: NowPlayingInfo?) { shown.append(info) }
}

/// What the fakes around the controls see and say.
@MainActor
private final class World {
    var ran: [CommandID] = []
    var seeks: [Double] = []
    var now = 100.0
    var title = "Come Together"
    var art: (path: String, art: EmbeddedArt)?
    var hasEngine = true

    func row(_ path: String) -> TrackRow {
        TrackRow(
            id: 1, path: art?.path ?? path, title: title, artist: "The Beatles",
            album: "Abbey Road", albumID: 1, albumArtist: nil, genre: "Rock", date: "1969",
            trackNumber: 1, discNumber: 1, codec: "flac", sampleRateHz: 96000, bitsPerSample: 24,
            durationSeconds: 259, addedSeconds: 0, art: art?.art)
    }
}

@MainActor
private func controls(
    _ world: World, artwork: ArtworkLoader = ArtworkLoader(maxPixelSize: 8, capacity: 1)
) throws -> (MediaControls, FakeRemote, FakeCenter, CommandDispatcher) {
    let remote = FakeRemote()
    let center = FakeCenter()
    let dispatcher = CommandDispatcher(
        bindings: try KeyBindings(AppCommands.all(), overrides: [:], rules: ChordRules()))
    for id in [CommandID.playPause, .stop, .nextTrack, .previousTrack] {
        dispatcher.handle(id, enabled: { world.hasEngine }, run: { world.ran.append(id) })
    }
    let controls = MediaControls(
        model: NowPlayingModel { world.row($0) }, dispatcher: dispatcher, remote: remote,
        center: center, artwork: artwork, seek: { world.seeks.append($0) },
        clock: { world.now })
    return (controls, remote, center, dispatcher)
}

private func update(
    _ event: PlaybackEvent?, status: PlaybackState.Status = .playing, current: Int? = 0,
    duration: Double? = 259
) -> PlaybackUpdate {
    var state = PlaybackState()
    state.queue = urls
    state.order = [0, 1]
    state.currentIndex = current
    state.status = status
    state.durationSeconds = duration
    return PlaybackUpdate(state: state, event: event)
}

@MainActor @Test func offersOnlyTheCommandsThatCanRunNow() throws {
    let world = World()
    let (controls, remote, _, _) = try controls(world)
    #expect(remote.enabledSets == [[]])
    controls.apply(update(.queueChanged, status: .stopped, duration: nil), positionSeconds: nil)
    #expect(
        remote.enabledSets.last == [.togglePlayPause, .play, .pause, .nextTrack, .previousTrack])
    controls.apply(update(.trackStarted(index: 0)), positionSeconds: 0)
    #expect(remote.enabledSets.last == Set(RemoteCommand.allCases))
    // The same set again isn't sent again.
    controls.apply(update(.paused, status: .paused), positionSeconds: 5)
    #expect(remote.enabledSets.count == 3)
    world.hasEngine = false
    controls.apply(update(.resumed), positionSeconds: 5)
    #expect(remote.enabledSets.last == [.changePlaybackPosition])
    controls.apply(update(.queueChanged, status: .stopped, current: nil), positionSeconds: nil)
    #expect(remote.enabledSets.last == [])
}

@MainActor @Test func eachRemoteCommandRunsItsRegistryCommand() throws {
    let world = World()
    let (controls, remote, _, _) = try controls(world)
    controls.apply(update(.trackStarted(index: 0)), positionSeconds: 0)
    #expect(remote.send(.togglePlayPause))
    #expect(remote.send(.nextTrack))
    #expect(remote.send(.previousTrack))
    #expect(remote.send(.stop))
    #expect(world.ran == [.playPause, .nextTrack, .previousTrack, .stop])

    // Play while playing and pause while paused do nothing, and say they're done.
    world.ran = []
    #expect(remote.send(.play))
    controls.apply(update(.paused, status: .paused), positionSeconds: 5)
    #expect(remote.send(.pause))
    #expect(world.ran == [])
    #expect(remote.send(.play))
    #expect(world.ran == [.playPause])

    // Off commands fail rather than run.
    controls.apply(update(.queueChanged, status: .stopped, current: nil), positionSeconds: nil)
    #expect(!remote.send(.togglePlayPause))
    #expect(world.ran == [.playPause])
}

@MainActor @Test func theScrubberSeeksWithinTheTrack() throws {
    let world = World()
    let (controls, remote, _, _) = try controls(world)
    #expect(!remote.send(.seek(toSeconds: 10)))
    controls.apply(update(.trackStarted(index: 0)), positionSeconds: 0)
    #expect(remote.send(.seek(toSeconds: 61.5)))
    #expect(remote.send(.seek(toSeconds: -3)))
    #expect(remote.send(.seek(toSeconds: 999)))
    #expect(world.seeks == [61.5, 0, 259])
}

@MainActor @Test func nowPlayingFollowsStartPauseResumeSeekAndStop() throws {
    let world = World()
    let (controls, _, center, _) = try controls(world)
    controls.apply(update(.queueChanged, status: .stopped), positionSeconds: nil)
    #expect(center.shown.isEmpty)

    controls.apply(update(.trackStarted(index: 0)), positionSeconds: nil)
    let started = try #require(center.shown.last ?? nil)
    #expect(started.title == "Come Together")
    #expect(started.artist == "The Beatles")
    #expect(started.album == "Abbey Road")
    #expect(started.durationSeconds == 259)
    #expect(started.elapsedSeconds == 0)
    #expect(started.rate == 1)

    world.now += 30
    controls.apply(update(.paused, status: .paused), positionSeconds: 29.9)
    #expect(center.shown.last??.elapsedSeconds == 29.9)
    #expect(center.shown.last??.rate == 0)

    world.now += 60
    controls.apply(update(.resumed), positionSeconds: 29.9)
    #expect(center.shown.last??.elapsedSeconds == 29.9)
    #expect(center.shown.last??.rate == 1)

    // The seek's target, since the output may not have caught up.
    controls.apply(update(.seeked(seconds: 120)), positionSeconds: 31)
    #expect(center.shown.last??.elapsedSeconds == 120)

    controls.apply(update(.trackStarted(index: 1), current: 1), positionSeconds: 0.01)
    #expect(center.shown.last??.elapsedSeconds == 0.01)

    controls.apply(update(.stopped, status: .stopped), positionSeconds: nil)
    #expect(center.shown.count == 6)
    #expect(center.shown.last == .some(nil))
    // Cleared once.
    controls.apply(update(.queueChanged, status: .stopped), positionSeconds: nil)
    #expect(center.shown.count == 6)
}

@MainActor @Test func eventsThatChangeNothingShownSetNothing() throws {
    let world = World()
    let (controls, _, center, _) = try controls(world)
    controls.apply(update(.trackStarted(index: 0)), positionSeconds: 0)
    world.now += 10
    for event: PlaybackEvent in [
        .repeatChanged, .shuffleChanged, .queueChanged, .underrun(frames: 10),
        .trackEnded(index: 0),
    ] {
        controls.apply(update(event), positionSeconds: 10)
    }
    #expect(center.shown.count == 1)
}

@MainActor @Test func aChangeBetweenStateChangesCarriesTheTimeOn() throws {
    let world = World()
    let (controls, _, center, _) = try controls(world)
    controls.apply(update(.trackStarted(index: 0)), positionSeconds: 10)
    world.now += 5
    world.title = "Something"
    controls.libraryChanged()
    #expect(center.shown.last??.title == "Something")
    #expect(center.shown.last??.elapsedSeconds == 15)

    // Paused, the time stands still.
    controls.apply(update(.paused, status: .paused), positionSeconds: 15)
    world.now += 100
    world.title = "Else"
    controls.libraryChanged()
    #expect(center.shown.last??.elapsedSeconds == 15)
    #expect(center.shown.count == 4)
}

@MainActor @Test func artIsReadOffTheMainThreadThenShownWithTheTimeCarriedOn() async throws {
    let world = World()
    world.art = try fileWithArt(width: 1200, height: 800)
    let artwork = ArtworkLoader(maxPixelSize: MediaControls.artPixels, capacity: 2)
    let (controls, _, center, _) = try controls(world, artwork: artwork)
    controls.apply(update(.trackStarted(index: 0)), positionSeconds: 2)
    #expect(center.shown.count == 1)
    #expect(center.shown.last??.art == nil)
    world.now += 3
    let deadline = Date().addingTimeInterval(5)
    while center.shown.count < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    let shown = try #require(center.shown.last ?? nil)
    let art = try #require(shown.art)
    #expect(art.width == MediaControls.artPixels)
    #expect(art.height == MediaControls.artPixels * 2 / 3)
    #expect(shown.elapsedSeconds == 5)

    // The next time it's the same track, the cached art comes with the first info.
    controls.apply(update(.stopped, status: .stopped), positionSeconds: nil)
    controls.apply(update(.trackStarted(index: 1), current: 1), positionSeconds: 0)
    #expect(center.shown.last??.art != nil)
}

@Test func artFitsTheBoxItsAskedForWithoutGrowing() {
    let image = CGSize(width: 512, height: 341)
    #expect(
        NowPlayingInfo.artSize(image, fitting: CGSize(width: 100, height: 100))
            == CGSize(width: 100, height: 341 * 100 / 512.0))
    #expect(
        NowPlayingInfo.artSize(image, fitting: CGSize(width: 2000, height: 2000)) == image)
    #expect(NowPlayingInfo.artSize(.zero, fitting: CGSize(width: 10, height: 10)) == .zero)
}

@MainActor @Test func theDockMenuShowsTheTrackAndTheTransportCommands() throws {
    let world = World()
    let (controls, _, _, dispatcher) = try controls(world)
    let dock = DockMenu(model: controls.model, dispatcher: dispatcher)
    let transport: [DockMenu.Entry] = [
        .command(.playPause, title: "Play/Pause", enabled: true),
        .command(.nextTrack, title: "Next Track", enabled: true),
        .command(.previousTrack, title: "Previous Track", enabled: true),
    ]
    #expect(dock.entries() == transport)
    controls.apply(update(.trackStarted(index: 0)), positionSeconds: 0)
    #expect(
        dock.entries()
            == [.label("Come Together"), .label("The Beatles — Abbey Road"), .separator]
            + transport)
    world.hasEngine = false
    #expect(
        dock.entries().suffix(3) == [
            .command(.playPause, title: "Play/Pause", enabled: false),
            .command(.nextTrack, title: "Next Track", enabled: false),
            .command(.previousTrack, title: "Previous Track", enabled: false),
        ])
    let menu = dock.menu()
    #expect(menu.items.map(\.title).suffix(3) == ["Play/Pause", "Next Track", "Previous Track"])
    #expect(menu.items.allSatisfy { !$0.isEnabled || $0.isSeparatorItem })
}

/// A file holding some junk bytes, then a PNG of `width` by `height`.
private func fileWithArt(width: Int, height: Int) throws -> (path: String, art: EmbeddedArt) {
    let context = try #require(
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let png = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("media-controls-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("track.flac").path
    let prefix = 16
    try (Data(repeating: 7, count: prefix) + (png as Data)).write(to: URL(fileURLWithPath: path))
    return (
        path,
        EmbeddedArt(
            offset: prefix, byteCount: png.length, mimeType: pngMIMEType, unsynchronised: false)
    )
}
