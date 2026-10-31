import Foundation
import Testing

@testable import Library
@testable import Playback
@testable import QueueView

private let urls = (0..<3).map { URL(fileURLWithPath: "/m/\($0).flac") }

private func state(order: [Int], current: Int?) -> PlaybackState {
    var state = PlaybackState()
    state.queue = urls
    state.order = order
    state.currentIndex = current
    return state
}

@MainActor @Test func listsThePlayOrderAndMarksTheCurrentTrack() {
    var lookups = 0
    let model = QueueModel { path in
        lookups += 1
        guard path == urls[1].path else { return nil }
        return TrackRow(
            id: 2, path: path, title: "Song", artist: "Band", album: "Record", albumID: nil,
            albumArtist: nil, genre: nil, date: nil, trackNumber: nil, discNumber: nil,
            codec: "flac", sampleRateHz: 44100, bitsPerSample: 16, durationSeconds: 61,
            addedSeconds: 0, art: nil)
    }
    model.apply(state(order: [2, 1, 0], current: 1))
    #expect(model.count == 3)
    #expect(model.currentPosition == 1)
    #expect(model.item(at: 1) == model.item(at: 1))
    #expect(model.item(at: 1).title == "Song")
    #expect(model.item(at: 1).detail == "Band — Record")
    #expect(model.item(at: 0).title == "2")
    #expect(model.item(at: 0).detail == "/m")
    #expect(lookups == 2)
    #expect(model.summary == "3 tracks")
    model.apply(state(order: [], current: nil))
    #expect(model.currentPosition == nil)
}

@MainActor @Test func aFailedLookupStillListsTheFile() {
    struct Broken: Error {}
    let model = QueueModel { _ in throw Broken() }
    model.apply(state(order: [0], current: 0))
    #expect(model.item(at: 0).title == "0")
}

@MainActor @Test func aLibraryChangeDescribesRowsAgain() {
    var title = "Old"
    let model = QueueModel { path in
        TrackRow(
            id: 1, path: path, title: title, artist: nil, album: nil, albumID: nil,
            albumArtist: nil, genre: nil, date: nil, trackNumber: nil, discNumber: nil,
            codec: "flac", sampleRateHz: 44100, bitsPerSample: 16, durationSeconds: 1,
            addedSeconds: 0, art: nil)
    }
    model.apply(state(order: [0], current: 0))
    #expect(model.item(at: 0).title == "Old")
    title = "New"
    #expect(model.item(at: 0).title == "Old")
    model.libraryChanged()
    #expect(model.item(at: 0).title == "New")
}
