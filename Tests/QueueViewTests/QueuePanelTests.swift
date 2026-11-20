import AppKit
import KeyChord
import Testing

@testable import Library
@testable import Playback
@testable import QueueView

@MainActor @Test func deleteRemovesFromTheQueueBeforeAnyCommandBoundToIt() throws {
    let panel = QueuePanel(model: QueueModel { _ in nil })
    _ = panel.view
    var chords: [[KeyChord]] = []
    // Remove… has ⌫ in the track table; in the queue it removes queued tracks instead.
    panel.keyCommand = {
        chords.append($0)
        return .ran
    }
    func key(
        _ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
    panel.list.keyDown(with: try key("\u{7F}", code: 51))
    #expect(chords.isEmpty)
    panel.list.keyDown(with: try key(" ", code: 49))
    #expect(chords.map(\.first) == [KeyChord(.space)])
    // ⌘⌫ is Remove from Queue or Playlist's, which the user can rebind.
    panel.list.keyDown(with: try key("\u{7F}", code: 51, .command))
    #expect(chords.map(\.first) == [KeyChord(.space), KeyChord(.delete, .command)])
}

@MainActor @Test func aQueueRowsLengthIsSmallAtTheRightEdgeOnTheTitlesLine() throws {
    func laidOut(_ title: String, seconds: Double, current: Bool) -> QueueCell {
        let cell = QueueCell()
        cell.frame = NSRect(x: 0, y: 0, width: 240, height: 34)
        let row = TrackRow(
            id: 1, path: "/m/1.flac", title: title, artist: "Band", album: "Record",
            albumID: nil, albumArtist: nil, genre: nil, date: nil, trackNumber: nil,
            discNumber: nil, codec: "flac", sampleRateHz: 44100, bitsPerSample: 16,
            durationSeconds: seconds, addedSeconds: 0, art: nil)
        cell.show(
            QueueItem(url: URL(fileURLWithPath: row.path, isDirectory: false), row: row),
            current: current)
        cell.layoutSubtreeIfNeeded()
        return cell
    }
    // The baseline of `label`'s first line, in the cell's coordinates.
    func baseline(_ label: NSTextField, in cell: QueueCell) -> CGFloat {
        let frame = cell.convert(label.bounds, from: label)
        return cell.isFlipped
            ? frame.minY + label.firstBaselineOffsetFromTop
            : frame.maxY - label.firstBaselineOffsetFromTop
    }
    let cells = [
        laidOut("Jóga", seconds: 439, current: false),
        laidOut(String(repeating: "A long title ", count: 8), seconds: 61, current: true),
    ]
    // Where the text of `label` lines up, without the field's own padding, in the cell.
    func edges(_ label: NSTextField, in cell: QueueCell) -> NSRect {
        let frame = cell.convert(label.bounds, from: label)
        return label.alignmentRect(forFrame: frame)
    }
    for cell in cells {
        let length = edges(cell.length, in: cell)
        let title = edges(cell.title, in: cell)
        #expect(abs(length.maxX - (240 - QueueCell.inset)) < 0.5, "\(length)")
        #expect(title.maxX <= length.minX, "the title truncates before the length")
        #expect(abs(baseline(cell.length, in: cell) - baseline(cell.title, in: cell)) < 0.5)
        #expect(cell.length.font?.pointSize == cell.detail.font?.pointSize)
    }
}

/// A hidden queue doesn't look up its rows again for each library refresh of a scan; it lists
/// the change once it shows.
@MainActor @Test func aHiddenQueueListsALibraryChangeOnceItShows() throws {
    var title = "Old"
    var lookups = 0
    let panel = QueuePanel(
        model: QueueModel { path in
            lookups += 1
            return TrackRow(
                id: 1, path: path, title: title, artist: nil, album: nil, albumID: nil,
                albumArtist: nil, genre: nil, date: nil, trackNumber: nil, discNumber: nil,
                codec: "flac", sampleRateHz: 44100, bitsPerSample: 16, durationSeconds: 1,
                addedSeconds: 0, art: nil)
        })
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
    var state = PlaybackState()
    state.queue = [URL(fileURLWithPath: "/m/1.flac", isDirectory: false)]
    state.order = [0]
    state.currentIndex = 0
    panel.show(state)
    window.displayIfNeeded()
    #expect(lookups == 1)
    func shownTitle() -> String? {
        (table.view(atColumn: 0, row: 0, makeIfNecessary: false) as? NSTableCellView)?
            .textField?.stringValue
    }
    panel.isShown = false
    title = "New"
    for _ in 0..<3 { panel.libraryChanged() }
    window.displayIfNeeded()
    #expect(lookups == 1)
    panel.isShown = true
    window.displayIfNeeded()
    #expect(lookups == 2)
    #expect(shownTitle() == "▶ New")
    // Shown, a change is listed at once.
    title = "Newer"
    panel.libraryChanged()
    window.displayIfNeeded()
    #expect(shownTitle() == "▶ Newer")
}
