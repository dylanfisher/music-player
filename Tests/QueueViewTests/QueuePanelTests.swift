import AppKit
import KeyChord
import Testing

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
    func key(_ characters: String, code: UInt16) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
    panel.list.keyDown(with: try key("\u{7F}", code: 51))
    #expect(chords.isEmpty)
    panel.list.keyDown(with: try key(" ", code: 49))
    #expect(chords.map(\.first) == [KeyChord(.space)])
}
