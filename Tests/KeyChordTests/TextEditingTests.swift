import AppKit
import Testing

@testable import KeyChord

@Test func textEditingChordsAreCaretMovesAndDeletions() {
    for chord in [
        KeyChord(.left, .command), KeyChord(.right, [.command, .shift]),
        KeyChord(.delete, .command), KeyChord(.left, .option), KeyChord(.delete, .option),
    ] {
        #expect(chord.isTextEditing, "\(chord)")
    }
    for chord in [
        KeyChord(.left, [.option, .command]), KeyChord(.down, .command), KeyChord("a", .command),
        KeyChord(.left), KeyChord(.delete, .control),
    ] {
        #expect(!chord.isTextEditing, "\(chord)")
    }
}

@MainActor
private func editedField(_ text: String) throws -> (NSWindow, NSTextView) {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled],
        backing: .buffered, defer: false)
    let field = NSTextField()
    field.frame = NSRect(x: 10, y: 10, width: 200, height: 24)
    window.contentView?.addSubview(field)
    field.stringValue = text
    #expect(window.makeFirstResponder(field))
    let editor = try #require(field.currentEditor() as? NSTextView)
    editor.setSelectedRange(NSRange(location: text.count, length: 0))
    return (window, editor)
}

@MainActor
private func key(
    _ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags, in window: NSWindow
) throws -> NSEvent {
    try #require(
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
}

/// ⌘← is Previous Track and ⌘⌫ Remove from Queue in the menu bar; a field being edited keeps
/// them.
@MainActor @Test func theFieldBeingEditedTakesTextEditingChords() throws {
    let (window, editor) = try editedField("abba")
    let left = String(Character(Unicode.Scalar(UInt32(NSLeftArrowFunctionKey))!))
    #expect(
        window.editTextFirst(try key(left, 123, [.command, .function, .numericPad], in: window)))
    #expect(editor.selectedRange().location == 0)

    let (other, otherEditor) = try editedField("abba")
    #expect(other.editTextFirst(try key("\u{7F}", 51, .command, in: other)))
    #expect(otherEditor.string.isEmpty)

    // Any other chord, and any chord with no field being edited, is left to the menu bar.
    #expect(!other.editTextFirst(try key("k", 40, .command, in: other)))
    other.makeFirstResponder(nil)
    #expect(!other.editTextFirst(try key("\u{7F}", 51, .command, in: other)))
}
