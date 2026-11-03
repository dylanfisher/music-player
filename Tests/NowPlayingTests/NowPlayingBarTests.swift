import AppKit
import Artwork
import Foundation
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
    for seekBar in [bar.slider, bar.statusBar.seekBar] {
        seekBar.frame = NSRect(x: 0, y: 0, width: 100, height: SeekBar.heightPoints)
    }
    return bar
}

@MainActor @Test func theSeekBarsAreOffWithoutALength() {
    let bar = bar()
    bar.apply(update(.trackStarted(index: 0), duration: nil))
    #expect(!bar.slider.isEnabled && !bar.statusBar.seekBar.isEnabled)
    bar.statusBar.seekBar.press(atX: 50)
    #expect(bar.statusBar.seekBar.fraction == 0)
    bar.apply(update(.trackStarted(index: 0), duration: 0))
    #expect(!bar.slider.isEnabled)
    bar.apply(update(.trackStarted(index: 0), duration: 100))
    #expect(bar.slider.isEnabled && bar.statusBar.seekBar.isEnabled)
    bar.setEnabled(false)
    #expect(!bar.slider.isEnabled)
}

@MainActor @Test func aTrackChangeLetsGoOfADragWithoutSeeking() {
    let bar = bar()
    bar.apply(update(.trackStarted(index: 0), duration: 100))
    let seekBar = bar.statusBar.seekBar
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
