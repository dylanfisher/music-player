import Foundation
import Testing

@testable import Library
@testable import NowPlaying
@testable import Playback

private let urls = ["/m/a.flac", "/m/b.flac"].map(URL.init(fileURLWithPath:))

private func row(_ path: String) -> TrackRow {
    TrackRow(
        id: 1, path: path, title: "Come Together", artist: "The Beatles", album: "Abbey Road",
        albumID: 1, albumArtist: nil, genre: "Rock", date: "1969", trackNumber: 1, discNumber: 1,
        codec: "flac", sampleRateHz: 96000, bitsPerSample: 24, durationSeconds: 259,
        addedSeconds: 0, art: nil)
}

private func update(
    _ event: PlaybackEvent?, current: Int? = 0, status: PlaybackState.Status = .playing,
    output: String? = nil, duration: Double? = 259
) -> PlaybackUpdate {
    var state = PlaybackState()
    state.queue = urls
    state.order = [0, 1]
    state.currentIndex = current
    state.status = status
    state.outputFormat = output
    state.durationSeconds = duration
    return PlaybackUpdate(state: state, event: event)
}

@MainActor @Test func showsTheCurrentTracksRowAndTheFormatLine() {
    var lookups: [String] = []
    let model = NowPlayingModel { path in
        lookups.append(path)
        return path == urls[0].path ? row(path) : nil
    }
    #expect(model.title == "Not Playing")
    model.apply(update(.trackStarted(index: 0), output: "ADI-2 DAC: 2 ch @ 96 kHz, hog mode"))
    #expect(model.title == "Come Together")
    #expect(model.subtitle == "The Beatles — Abbey Road")
    #expect(model.formatLine == "96 kHz 24-bit FLAC → ADI-2 DAC: 2 ch @ 96 kHz, hog mode")
    // The same track again doesn't look it up again.
    model.apply(update(.paused, status: .paused))
    #expect(lookups == [urls[0].path])
    // A file the library doesn't know shows its name.
    model.apply(update(.trackStarted(index: 1), current: 1))
    #expect(model.title == "b")
    #expect(model.subtitle == "")
    #expect(model.formatLine == "")
}

@MainActor @Test func saysWhatWentWrongUntilPlaybackCarriesOn() {
    let model = NowPlayingModel { row($0) }
    model.apply(update(.deviceLost, status: .paused))
    #expect(model.message?.contains("went away") == true)
    model.apply(update(.deviceReturned, status: .paused))
    #expect(model.message?.contains("Press Play") == true)
    model.apply(update(.resumed))
    #expect(model.message == nil)
    model.apply(update(.trackFailed(urls[1], reason: "not audio")))
    #expect(model.message == "Couldn't play b.flac: not audio")
    model.apply(update(.trackStarted(index: 0)))
    #expect(model.message == nil)
}

@MainActor @Test func timesCountUpAndDown() {
    let model = NowPlayingModel { row($0) }
    model.apply(update(.trackStarted(index: 0)))
    #expect(model.times(positionSeconds: 62) == ("1:02", "-3:17"))
    #expect(model.times(positionSeconds: 400) == ("4:19", "-0:00"))
    #expect(model.times(positionSeconds: nil) == ("", ""))
}
