import AppKit
import Testing

@testable import LibraryBrowser

/// ⌘← and ⌘→ are Previous and Next Track in the menu bar; the search field keeps them while it's
/// edited, so the caret still moves.
@MainActor @Test func theSearchFieldKeepsCommandArrowsWhileEdited() throws {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled],
        backing: .buffered, defer: false)
    let field = SearchField()
    field.frame = NSRect(x: 10, y: 10, width: 200, height: 24)
    window.contentView?.addSubview(field)
    field.stringValue = "abba"
    #expect(window.makeFirstResponder(field))
    let editor = try #require(field.currentEditor() as? NSTextView)
    editor.setSelectedRange(NSRange(location: 4, length: 0))
    let left = String(Character(Unicode.Scalar(UInt32(NSLeftArrowFunctionKey))!))
    let event = try #require(
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .function, .numericPad],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: left,
            charactersIgnoringModifiers: left, isARepeat: false, keyCode: 123))
    #expect(field.performKeyEquivalent(with: event))
    #expect(editor.selectedRange().location == 0)
}
