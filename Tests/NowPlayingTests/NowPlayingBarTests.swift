import AppKit
import Artwork
import Fixtures
import Foundation
import HALOutput
import Settings
import Testing

@testable import Library
@testable import NowPlaying
@testable import Playback

private let urls = ["/m/a.flac", "/m/b.flac"].map(URL.init(fileURLWithPath:))

private func update(_ event: PlaybackEvent?, current: Int? = 0, duration: Double?)
    -> PlaybackUpdate
{
    var state = PlaybackState()
    state.queue = urls
    state.order = [0, 1]
    state.currentIndex = current
    state.status = .playing
    state.durationSeconds = duration
    return PlaybackUpdate(state: state, event: event)
}

/// A bar over a model whose every track is the same row, connected as if to an engine.
@MainActor
private func bar() -> NowPlayingBar {
    let model = NowPlayingModel { path in
        TrackRow(
            id: 1, path: path, title: "Song", artist: nil, album: nil, albumID: 1,
            albumArtist: nil, genre: nil, date: nil, trackNumber: nil, discNumber: nil,
            codec: "flac", sampleRateHz: 44100, bitsPerSample: 16, durationSeconds: 100,
            addedSeconds: 0, art: nil)
    }
    let bar = NowPlayingBar(model: model, artwork: ArtworkLoader(maxPixelSize: 8, capacity: 1))
    bar.setEnabled(true)
    for seekBar in [bar.header.seekBox.bar, bar.statusBar.seekBox.bar] {
        seekBar.frame = NSRect(x: 0, y: 0, width: 100, height: SeekBar.heightPoints)
    }
    return bar
}

@MainActor @Test func theSeekBarsAreOffWithoutALength() {
    let bar = bar()
    bar.apply(update(.trackStarted(index: 0), duration: nil))
    #expect(!bar.header.seekBox.bar.isEnabled && !bar.statusBar.seekBox.bar.isEnabled)
    bar.statusBar.seekBox.bar.press(atX: 50)
    #expect(bar.statusBar.seekBox.bar.fraction == 0)
    bar.apply(update(.trackStarted(index: 0), duration: 0))
    #expect(!bar.header.seekBox.bar.isEnabled)
    bar.apply(update(.trackStarted(index: 0), duration: 100))
    #expect(bar.header.seekBox.bar.isEnabled && bar.statusBar.seekBox.bar.isEnabled)
    bar.setEnabled(false)
    #expect(!bar.header.seekBox.bar.isEnabled)
}

@MainActor @Test func aTrackChangeLetsGoOfADragWithoutSeeking() {
    let bar = bar()
    bar.apply(update(.trackStarted(index: 0), duration: 100))
    let seekBar = bar.statusBar.seekBox.bar
    var seeks: [Bool] = []
    seekBar.seek = { _, done in seeks.append(done) }
    seekBar.press(atX: 20)
    seekBar.drag(toX: 60)
    #expect(seekBar.isTracking)
    bar.apply(update(.trackStarted(index: 1), current: 1, duration: 100))
    #expect(!seekBar.isTracking)
    seekBar.release()
    #expect(seeks == [true, false])
}

/// AppKit draws a covered window, so the bar stops its own updates while the window doesn't
/// show, through track changes too, and starts them again when it shows.
@MainActor @Test func thePositionUpdatesOnlyWhileTheWindowShows() {
    let bar = bar()
    bar.apply(update(.trackStarted(index: 0), duration: 100))
    #expect(bar.ticks)
    bar.windowShowsChanged(false)
    #expect(!bar.ticks)
    bar.apply(update(.trackStarted(index: 1), current: 1, duration: 100))
    #expect(!bar.ticks)
    bar.windowShowsChanged(true)
    #expect(bar.ticks)
    var paused = update(nil, current: 1, duration: 100)
    paused.state.status = .paused
    bar.apply(paused)
    #expect(!bar.ticks)
    bar.windowShowsChanged(true)
    #expect(!bar.ticks)
}

/// A click seeks a `DeviceOutput` reading from a slow NAS, whose control thread takes a while
/// to do the seek. From the click on, neither bar goes back to the time before it.
@MainActor @Test func aClickNeverDrawsTheTimeFromBeforeIt() async throws {
    let track = try hiResTrack(in: try defaultPlaybackFixturesDirectory())
    let output = try DeviceOutput(
        DeviceChoice(provider: NullDevice(speed: 1), digitalVolume: false, gain: 1, formats: nil),
        fileLatency: FileLatency(openSeconds: 0, readSeconds: 0.05))
    defer { output.close() }
    let engine = PlaybackEngine(output: output)
    let bar = bar()
    bar.connect(engine)
    await engine.setQueue([track])
    await engine.play()
    let started = Date().addingTimeInterval(10)
    while Date() < started {
        let position = await engine.position() ?? 0
        if bar.header.seekBox.bar.isEnabled, position >= 0.2 { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try #require(bar.header.seekBox.bar.isEnabled)
    bar.header.seekBox.bar.press(atX: 50)
    bar.header.seekBox.bar.release()
    var drawn: [Double] = []
    var times: Set<String> = []
    let deadline = Date().addingTimeInterval(1.5)
    while Date() < deadline {
        drawn += [bar.header.seekBox.bar.fraction, bar.statusBar.seekBox.bar.fraction]
        times.formUnion([bar.header.seekBox.times.elapsed, bar.statusBar.seekBox.times.elapsed])
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    #expect(drawn.allSatisfy { $0 >= 0.5 }, "drawn after the click: \(drawn.filter { $0 < 0.5 })")
    #expect(times.isSubset(of: ["1:00", "1:01"]), "times drawn after the click: \(times)")
}

/// Where `box` is in `view`, laid out at `size`: a point on the elapsed time, one on the bar,
/// one on the total, and one on the box's own edge.
@MainActor
private func points(of box: SeekBox, in view: NSView) -> [NSPoint] {
    view.layoutSubtreeIfNeeded()
    let frame = box.convert(box.bounds, to: view)
    let bar = box.bar.convert(box.bar.bounds, to: view)
    return [
        NSPoint(x: frame.minX + 1, y: frame.midY), NSPoint(x: bar.minX - 10, y: frame.midY),
        NSPoint(x: bar.midX, y: bar.midY), NSPoint(x: bar.maxX + 10, y: frame.midY),
    ]
}

/// The toolbar's status and the status bar both sit where a mouse down on a view that allows
/// it drags the window: the title bar, and with glass a full-size content view.
@MainActor @Test func aMouseDownOnEitherSeekBoxNeverMovesTheWindow() throws {
    let bar = bar()
    bar.status.frame = NSRect(x: 0, y: 0, width: 400, height: CGFloat(HeaderPart.artPoints))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
        styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let content = try #require(window.contentView)
    let statusSeek = try #require(bar.statusBar.view(for: .seek))
    statusSeek.frame = NSRect(x: 100, y: 0, width: 300, height: SeekBox.heightPoints)
    content.addSubview(statusSeek)
    for (box, view) in [(bar.header.seekBox, bar.status), (bar.statusBar.seekBox, content)] {
        let frame = try #require(content.superview)
        for point in points(of: box, in: view) {
            let inWindow = view === content ? content.convert(point, to: frame) : point
            let hit = try #require((view === content ? frame : view).hitTest(inWindow))
            #expect(hit === box || hit === box.bar, "\(point) hit \(hit)")
            #expect(!hit.mouseDownCanMoveWindow, "\(point) hit \(hit)")
        }
    }
}
