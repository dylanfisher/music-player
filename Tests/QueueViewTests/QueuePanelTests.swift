import AppKit
import KeyChord
import Testing

@testable import Library
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
