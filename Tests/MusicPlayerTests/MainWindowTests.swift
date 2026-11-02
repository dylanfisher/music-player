import AppKit
import Settings
import Testing

@testable import MusicPlayer

/// Column spacing and a vertical scroller, which the table adds to its columns' widths.
private let tableExtraPoints = 6.0 + 15.0

@MainActor @Test func theDefaultColumnsFitBesideTheSidebarAndQueue() {
    let settings = AppState()
    let columns = settings.trackTable.defaultValue.columns
    let needed = columns.reduce(0) { $0 + $1.width + 6 } + tableExtraPoints
    let room =
        Double(MainWindow.defaultSize.width) - Double(settings.sidebarWidth.defaultValue)
        - Double(settings.queueWidth.defaultValue)
    #expect(needed <= room)
}

@Test func aFrameOnADisplayThatsGoneIsCentered() {
    let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)
    let onScreen = WindowFrame(x: 100, y: 50, width: 1280, height: 760)
    #expect(
        restoredFrame(onScreen, screens: [screen])
            == NSRect(x: 100, y: 50, width: 1280, height: 760))
    // It was on a second display to the right.
    #expect(
        restoredFrame(WindowFrame(x: 1600, y: 0, width: 800, height: 600), screens: [screen]) == nil
    )
    #expect(restoredFrame(nil, screens: [screen]) == nil)
}

/// A split of empty views in a window of the default size, as the main window lays it out.
@MainActor
private func split(queueVisible: Bool) -> (MainSplit, NSWindow, content: NSView) {
    let views = (0..<3).map { _ in
        let controller = NSViewController()
        controller.view = NSView()
        return controller
    }
    let split = MainSplit(
        sidebar: views[0], content: views[1], queue: views[2], sidebarWidth: 180,
        queueWidth: 220)
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: MainWindow.defaultSize),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentView = split.view
    window.layoutIfNeeded()
    split.restore(sidebarVisible: true, queueVisible: queueVisible)
    return (split, window, views[1].view)
}

@MainActor @Test func aHiddenQueueLeavesNoDividerAndStaysHiddenAsTheWindowResizes() {
    let (split, window, content) = split(queueVisible: true)
    split.toggleQueue()
    for width in [1000.0, 1400.0] {
        window.setFrame(NSRect(x: 0, y: 0, width: width, height: 760), display: false)
        window.layoutIfNeeded()
        let splitView = split.controller.splitView
        #expect(!split.isQueueVisible)
        // The browser reaches the window's edge: no divider is left to drag.
        split.view.layoutSubtreeIfNeeded()
        #expect(abs(content.convert(content.bounds, to: nil).maxX - width) < 0.5)
        #expect(split.controller.splitView(splitView, shouldHideDividerAt: 1))
    }
}

@MainActor @Test func theQueueComesBackAtItsWidth() {
    let (split, window, _) = split(queueVisible: false)
    #expect(!split.isQueueVisible)
    split.toggleQueue()
    window.layoutIfNeeded()
    let queue = split.controller.splitViewItems[2].viewController.view
    #expect(split.isQueueVisible)
    #expect(abs(queue.frame.width - 220) <= 1)
}

/// Records the key presses no responder took, which AppKit beeps for.
private final class RecordingWindow: SilentEscapeWindow {
    var unhandled: [Selector] = []

    override func noResponder(for eventSelector: Selector) { unhandled.append(eventSelector) }
}

@MainActor @Test func escapeInAListDoesNothingWhereOtherKeysStillBeep() throws {
    let window = RecordingWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
        backing: .buffered, defer: false)
    let table = NSTableView()
    window.contentView = table
    #expect(window.makeFirstResponder(table))
    func press(_ characters: String, _ keyCode: UInt16) throws {
        table.keyDown(
            with: try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)))
    }
    try press("\u{1B}", 53)
    #expect(window.unhandled.isEmpty)
    #expect(table.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil))
    // A key nothing takes still reaches AppKit's beep.
    try press("\u{F704}", 122)
    #expect(window.unhandled == [#selector(NSResponder.keyDown(with:))])
}
