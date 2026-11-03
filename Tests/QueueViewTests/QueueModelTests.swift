import AppKit
import DisplayText
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

@MainActor @Test func listsThePlayOrderFromTheCurrentTrackOn() {
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
    // Track 2 has played, so it isn't listed.
    model.apply(state(order: [2, 1, 0], current: 1))
    #expect(model.count == 2)
    #expect(model.currentRow == 0)
    #expect(model.item(at: 0) == model.item(at: 0))
    #expect(model.item(at: 0).title == "Song")
    #expect(model.item(at: 0).detail == "Band — Record")
    #expect(model.item(at: 1).title == "0")
    #expect(model.item(at: 1).detail == "/m")
    #expect(lookups == 2)
    #expect(model.summary == "2 tracks")
    model.apply(state(order: [2, 1, 0], current: nil))
    #expect(model.count == 3)
    #expect(model.item(at: 0).title == "2")
    model.apply(state(order: [], current: nil))
    #expect(model.currentRow == nil)
    #expect(model.count == 0)
}

@MainActor @Test func rowsMapToPositionsInPlayOrder() {
    let model = QueueModel { _ in nil }
    model.apply(state(order: [2, 1, 0], current: 1))
    #expect(model.position(ofRow: 0) == 1)
    #expect(model.positions(ofRows: [0, 1]) == [1, 2])
    // A drop below the last row goes to the end.
    #expect(model.position(ofRow: model.count) == 3)
    model.apply(state(order: [2, 1, 0], current: nil))
    #expect(model.position(ofRow: 1) == 1)
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

@MainActor @Test func theCurrentTracksRowIsMarkedAndTheMarkFollowsIt() {
    let model = QueueModel { _ in nil }
    let panel = QueuePanel(model: model)
    _ = panel.view
    let table = NSTableView()
    func marked() -> [Int] {
        (0..<model.count).filter {
            (panel.tableView(table, rowViewForRow: $0) as? MarkedRowView)?.isMarked == true
        }
    }
    model.apply(state(order: [2, 1, 0], current: 1))
    #expect(marked() == [0])
    // An identifier lets the table reuse the row view.
    #expect(panel.tableView(table, rowViewForRow: 0)?.identifier != nil)
    model.apply(state(order: [2, 1, 0], current: 0))
    #expect(marked() == [0])
    #expect(model.count == 1)
    model.apply(state(order: [2, 1, 0], current: nil))
    #expect(marked().isEmpty)
}
