import AppKit
import Testing

@testable import Metadata
@testable import TagEditor

private let parent = NSRect(x: 100, y: 100, width: 1000, height: 700)

@MainActor @Test func aWindowStartsAtThePlaceSavedWhileItsOnAScreen() {
    let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900)]
    let place = NSPoint(x: 600, y: 500)
    #expect(TagEditorWindow.start(place: place, parent: parent, screens: screens) == place)
    let nearParent = NSPoint(x: 140, y: 760)
    #expect(TagEditorWindow.start(place: nil, parent: parent, screens: screens) == nearParent)
    // A screen unplugged since held it.
    #expect(
        TagEditorWindow.start(place: NSPoint(x: 2000, y: 500), parent: parent, screens: screens)
            == nearParent)
}

/// The user's moves are reported; the app's own placing and the window growing once its files
/// are read are not.
@MainActor @Test func onlyAMoveOfTheUsersIsReported() throws {
    let main = NSWindow(
        contentRect: parent, styleMask: [.titled], backing: .buffered, defer: false)
    let editor = TagEditorWindow(paths: ["/music/a.flac"])
    var moves: [NSPoint] = []
    editor.moved = { moves.append($0) }
    let screen = try #require(NSScreen.main).visibleFrame
    let place = NSPoint(x: screen.minX + 200, y: screen.maxY - 100)
    editor.show(beside: main, at: place, avoiding: [])
    defer { editor.close() }
    #expect(editor.corner == place)
    editor.load(
        TagEditorModel(tracks: [EditableTrack(path: "/music/a.flac", tags: TrackTags(), art: nil)]))
    #expect(editor.corner == place, "it grows down from its corner")
    #expect(moves.isEmpty, "\(moves)")

    let dragged = NSPoint(x: place.x + 50, y: place.y - 30)
    editor.window.setFrameTopLeftPoint(dragged)
    #expect(moves == [dragged], "\(moves)")

    // A second window at the same place steps past the first.
    let second = TagEditorWindow(paths: ["/music/b.flac"])
    second.show(beside: main, at: dragged, avoiding: [editor.corner])
    defer { second.close() }
    #expect(second.corner.x > dragged.x)
    #expect(second.corner.y < dragged.y)
}
