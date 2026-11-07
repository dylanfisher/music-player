import AppKit
import Artwork
import Fixtures
import Foundation
import HALOutput
import Testing

@testable import Library
@testable import NowPlaying
@testable import Playback
@testable import Settings

private let urls = ["/m/a.flac", "/m/b.flac"].map(URL.init(fileURLWithPath:))

private struct DeviceStopped: PlaybackFailure {
    var description: String { "DeviceStopped(status: -50)" }
    var userMessage: String { "the device stopped" }
}

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
    bar.apply(update(.trackStarted(index: 0), duration: 100))
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

/// With nothing playing the art, gray box and all, doesn't show; it keeps its place, so the
/// parts beside it stay where they are when a track starts.
@MainActor @Test func theArtShowsOnlyWhileATrackIsCurrent() {
    let bar = bar()
    let status = bar.header.view
    status.frame = NSRect(x: 0, y: 0, width: 420, height: status.fittingSize.height)
    /// Where each part starts; the title's width follows its text.
    func frames() -> [NSPoint] {
        status.layoutSubtreeIfNeeded()
        return [bar.header.art, bar.header.titleLabel, bar.header.seekBox].map {
            $0.convert($0.bounds, to: status).origin
        }
    }
    let arts = [bar.header.art, bar.statusBar.art]
    #expect(arts.allSatisfy { $0.alphaValue == 0 })
    let before = frames()
    bar.apply(update(.trackStarted(index: 0), duration: 100))
    #expect(arts.allSatisfy { $0.alphaValue == 1 })
    #expect(frames() == before)
    bar.apply(update(.stopped, current: nil, duration: nil))
    #expect(arts.allSatisfy { $0.alphaValue == 0 })
}

/// The bar reports the window's title as the track starts and stops and as its template
/// changes.
@MainActor @Test func theBarReportsTheWindowTitle() {
    let bar = bar()
    var titles: [String?] = []
    bar.windowTitleChanged = { titles.append($0) }
    bar.apply(update(.trackStarted(index: 0), duration: 100))
    bar.windowTitle = TitleTemplate("{format}: {title}")
    bar.apply(update(.stopped, current: nil, duration: nil))
    #expect(titles == ["Song", "44.1 kHz 16-bit FLAC: Song", nil])
}

/// With nothing playing the toolbar's status draws nothing, no art box, title or seek bar,
/// and keeps its height, so the toolbar doesn't move when a track starts; the toolbar sets
/// its width.
@MainActor @Test func theToolbarsStatusIsEmptyWithNothingPlaying() throws {
    let bar = bar()
    let size = bar.status.fittingSize
    bar.status.frame = NSRect(origin: .zero, size: NSSize(width: 400, height: size.height))
    bar.status.layoutSubtreeIfNeeded()
    #expect(!bar.header.showsParts)
    #expect(bar.status.hitTest(NSPoint(x: 24, y: size.height / 2)) === bar.status)
    bar.apply(update(.trackStarted(index: 0), duration: 100))
    #expect(bar.header.showsParts && bar.status.fittingSize.height == size.height)
    #expect(bar.header.titleLabel.stringValue == "Song")
    bar.apply(update(.stopped, current: nil, duration: nil))
    #expect(!bar.header.showsParts && bar.status.fittingSize.height == size.height)
}

/// What went wrong shows with nothing playing, in the format line.
@MainActor @Test func aMessageShowsWithNothingPlaying() {
    let failed = bar()
    failed.apply(update(.failed(PlaybackProblem(DeviceStopped())), current: nil, duration: nil))
    #expect(failed.header.showsParts)
    #expect(failed.header.formatLabel.stringValue == "Playback stopped: the device stopped")
    // The reason stays through a rescan and a format change, which draw the status again.
    let unavailable = bar()
    unavailable.showUnavailable("No output device")
    for redraw in [
        { unavailable.libraryChanged() }, { unavailable.titleFormat = .titleLine },
    ] {
        redraw()
        #expect(unavailable.header.showsParts)
        #expect(unavailable.header.formatLabel.stringValue == "No output device")
        #expect(unavailable.header.formatLabel.textColor == .systemRed)
    }
}

/// A playback problem in the status bar has a question mark, and it and the line open the
/// details; another message has neither.
@MainActor @Test func aProblemInTheStatusBarOpensItsDetails() throws {
    let bar = bar()
    var opened: [ShownProblem] = []
    bar.problemOpened = { opened.append($0) }
    bar.apply(
        update(.trackFailed(urls[1], entry: 1, PlaybackProblem(DeviceStopped())), duration: nil))
    #expect(!bar.statusBar.problemButton.isHidden)
    click(bar.statusBar.problemButton)
    let format = try #require(bar.statusBar.view(for: .format) as? NSStackView)
    let label = try #require(format.arrangedSubviews.first as? NSTextField)
    let click = try #require(label.gestureRecognizers.first as? NSClickGestureRecognizer)
    _ = click.target?.perform(click.action)
    #expect(opened.count == 2)
    #expect(opened.first?.track == urls[1] && opened.first?.trackFormat == "44.1 kHz 16-bit FLAC")
    #expect(opened.first?.headline == "Couldn't play b.flac: the device stopped")
    bar.apply(update(.deviceLost, duration: nil))
    #expect(bar.statusBar.problemButton.isHidden)
    _ = click.target?.perform(click.action)
    #expect(opened.count == 2)
}

/// The title line follows its format, and leaves out the words before a field the track
/// doesn't have.
@MainActor @Test func theTitleLineFollowsItsFormat() {
    let bar = bar()
    bar.apply(update(.trackStarted(index: 0), duration: 100))
    // The track has no artist or album.
    #expect(bar.header.titleLineLabel.stringValue == "Song")
    bar.titleFormat = TitleTemplate("Now: {title}")
    #expect(bar.header.titleLineLabel.stringValue == "Now: Song")
    #expect(bar.header.titleLineLabel.toolTip == "Now: Song")
}

/// A line that comes out empty hides its label, which leaves no blank line in its column.
@MainActor @Test func anEmptyTitleLineHidesItsLabel() {
    let bar = bar()
    bar.apply(update(.trackStarted(index: 0), duration: 100))
    #expect(!bar.header.titleLineLabel.isHidden)
    // The track has no artist.
    bar.titleFormat = TitleTemplate("{artist}")
    #expect(bar.header.titleLineLabel.stringValue == "" && bar.header.titleLineLabel.isHidden)
    bar.titleFormat = .titleLine
    #expect(!bar.header.titleLineLabel.isHidden)
}

/// Each Custom Status item has its own views, laid out its own way, and shows the same track
/// as the status at the same time: the lines, the art and a seek bar that's on.
@MainActor @Test func theCustomStatusesShowTheSameTrackAsTheStatus() {
    let bar = bar()
    #expect(bar.customStatuses.count == ToolbarItem.customStatuses.count)
    let views = [bar.header.view] + bar.customStatuses.map(\.view)
    #expect(Set(views.map(ObjectIdentifier.init)).count == views.count)
    bar.customStatuses[0].apply(.defaultCustomStatus)
    bar.customStatuses[1].apply(
        BarLayout(
            center: BarColumn(parts: [.title, .format], width: .flexible, alignment: .center)))
    let headers = [bar.header] + bar.customStatuses
    #expect(headers.allSatisfy { !$0.showsParts })
    bar.titleFormat = TitleTemplate("Now: {title}")
    bar.apply(update(.trackStarted(index: 0), duration: 100))
    for header in headers {
        #expect(header.showsParts)
        #expect(header.titleLabel.stringValue == "Song")
        #expect(header.titleLineLabel.stringValue == "Now: Song")
        #expect(header.formatLabel.stringValue == bar.header.formatLabel.stringValue)
        #expect(header.art.alphaValue == 1)
        #expect(header.seekBox.bar.isEnabled)
    }
    bar.apply(update(.stopped, current: nil, duration: nil))
    #expect(headers.allSatisfy { !$0.showsParts && $0.art.alphaValue == 0 })
}
