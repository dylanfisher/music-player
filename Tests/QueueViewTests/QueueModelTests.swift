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

@MainActor @Test func dragsStayBelowTheCurrentTrack() {
    let model = QueueModel { _ in nil }
    let panel = QueuePanel(model: model)
    _ = panel.view
    let table = NSTableView()
    model.apply(state(order: [2, 1, 0], current: 1))
    #expect(model.dropRow(0) == 1)
    #expect(model.dropRow(2) == 2)
    #expect(panel.tableView(table, pasteboardWriterForRow: 0) == nil)
    #expect(panel.tableView(table, pasteboardWriterForRow: 1) != nil)
    model.apply(state(order: [2, 1, 0], current: nil))
    #expect(model.dropRow(0) == 0)
    #expect(panel.tableView(table, pasteboardWriterForRow: 0) != nil)
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

@MainActor @Test func theNextTrackStartingMovesTheRowsUpAndKeepsTheirSelection() throws {
    let tracks = (0..<6).map { URL(fileURLWithPath: "/m/\($0).flac", isDirectory: false) }
    func playing(_ current: Int?, order: [Int] = Array(0..<6)) -> PlaybackState {
        var state = PlaybackState()
        state.queue = tracks
        state.order = order
        state.currentIndex = current
        return state
    }
    let model = QueueModel { _ in nil }
    #expect(model.apply(playing(0)) == nil)
    #expect(model.apply(playing(2)) == 2)
    // Back, reordered, or stopped: anything but moving on lists the rows again.
    #expect(model.apply(playing(1)) == nil)
    #expect(model.apply(playing(3, order: [5, 4, 3, 2, 1, 0])) == nil)
    #expect(model.apply(playing(nil)) == nil)

    let panel = QueuePanel(model: QueueModel { _ in nil })
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 280, height: 400), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = panel.view
    defer { window.close() }
    func find(_ view: NSView) -> NSTableView? {
        view as? NSTableView ?? view.subviews.lazy.compactMap(find).first
    }
    let table = try #require(find(panel.view))
    panel.show(playing(0))
    window.displayIfNeeded()
    table.selectRowIndexes([3], byExtendingSelection: false)
    panel.show(playing(1))
    window.displayIfNeeded()
    #expect(table.numberOfRows == 5)
    // Still track 3, a row higher.
    #expect(table.selectedRowIndexes == [2])
    #expect((table.rowView(atRow: 0, makeIfNecessary: false) as? MarkedRowView)?.isMarked == true)
    let current = table.view(atColumn: 0, row: 0, makeIfNecessary: false) as? NSTableCellView
    #expect(current?.textField?.stringValue == "▶ 1")
}
